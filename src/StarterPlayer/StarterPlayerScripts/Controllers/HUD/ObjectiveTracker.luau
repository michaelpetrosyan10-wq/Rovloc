--!strict
-- ObjectiveTracker: what to do next, always one glance away (spec: onboarding brief §3-4).
--
--   * The tracker: a compact sheet top-left (top-right on touch, clear of the MENU / GOAL buttons): OBJECTIVE, the
--     current goal, a short tip for the floor, and the key that asks for directions. It shows fully when the goal
--     changes or the Objective action is pressed (Tab / d-pad right / the GOAL button) and fades out after
--     TutorialConfig.Timing.TrackerHold seconds idle, in the lobby it stays.
--   * Goals are read from what the server replicates (levelObjective / lobbyObjective):
--       lobby       get on the bus (the glowing arrows) -> stand on a pad to ready up; optional lines for the vote and
--                   the perk shop tick off once done; "you're ready, waiting for the squad"; the countdown; a full
--                   squad's waiting list;
--       every floor find the stairwell the run leaves it by (the tower of the route's exit: east, north-east, ...;
--                   AirlockController.exitStairwell reads it off the fire doors that are not jammed), and once its fire
--                   doors are counting down, get in (or hold it, from inside the vestibule);
--       Floor 1     after the HallwayGate slams: find a vent around it (the CriticalPath bypass grate), crawl through,
--                   then the stairwell again once past the gate;
--       Floor 4     cross the pool to the roof stairs;
--       the roof    out of the stair housing, find a way off (the parachute crate), "get to the parachutes!" once the
--                   door is smashed, then the gap with a pack on, the cord in freefall, and "you made it" on landing.
--   * The floor objective (ObjectiveService, ObjectiveState: ObjectiveLevel / ObjectiveSteps / ObjectiveUnlocked /
--     ObjectiveTimerEndsAt / ObjectiveTargets, my Carrying, my HeldItem): until the floor's exit unlocks the goal line is
--     the objective's title, each step a row with its count ("Fuses 1/3", "Survive while the door motor winds: 45s"),
--     done steps ticked and the current one marked, then the carried items ("Carrying: Fuse ×2"); a step changing or a
--     running countdown brings the sheet back. Once the exit unlocks the goal is the stairwell again (steps ticked).
--     The direction nudge then points at the ROOM of the nearest undone step's target (its centre, or its doorway nearest
--     me, labelled with the room's name), never at the item, first NudgeDelay after arriving on the floor and then every
--     NudgeCooldown (ObjectiveConfig.Tuning). The floor card adds "OBJECTIVE: <title>".
--   * A floating marker (BillboardGui on a client-side Attachment, through walls) hangs over the lobby's current step
--     (the bus's rear door, then the nearest free ready pad) until it is done.
--   * Directions: the Objective action shows a chevron around the crosshair pointing at the goal with its distance
--     and the same marker over it, for DirectionShow seconds, then cools down for DirectionCooldown (the key hint
--     counts it down), so it nudges without killing the tension.
--   * Floor title card: FLOOR 1 / MAIN HALLWAYS fades in centre-top when the squad reaches a new level (and at the
--     start of a run), held back while the HUD is hidden (cutscenes) for up to FloorCardWait seconds.
--   * In the lobby, a HOW TO PLAY button (H / d-pad left, or tap) under the goal replays the walkthrough.
-- Hidden while the HUD is hidden (cutscenes, jumpscares, results), in the Cutscene / Menu input contexts, under a
-- Cutscene / Jumpscare control lock, while the onboarding screens are up, and while this player is not playing
-- (downed: DownedController owns the screen; spectating; dead).
--
-- GetTrackerAlpha tells SquadPanel how much of the sheet shows (they share the top-right corner on touch).
--
-- Pure (tests/Specs/Onboarding.spec.luau): levelObjective, lobbyObjective, trackerAlpha, direction, bearing, beyond,
-- floorCard, floorCardAlpha, meters, nearest.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local InputConfig = require(ReplicatedStorage.Shared.Config.InputConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LobbyBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LobbyBuilder)
local LobbyLayout = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Layouts.Lobby)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local ParachuteMotion = require(ReplicatedStorage.Shared.Sequence.ParachuteMotion)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local TutorialConfig = require(ReplicatedStorage.Shared.Config.TutorialConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local ObjectiveState = require(ReplicatedStorage.Shared.Util.ObjectiveState)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local InputController = require(Controllers.Core.InputController)
local AirlockController = require(Controllers.Match.AirlockController)
local LobbyController = require(Controllers.Match.LobbyController)
local OnboardingController = require(Controllers.Match.OnboardingController)
local HUD = require(script.Parent)
local InputGlyphs = require(script.Parent.InputGlyphs)
local UIKit = require(script.Parent.UIKit)

local log = Log.new("Objective")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local Palette = UIKit.Palette
local Timing = TutorialConfig.Timing

export type TargetKind = "Exit" | "BypassVent" | "RoofDoor" | "Crate" | "Gap" | "Bus" | "Pad" | "Floor"
export type AirlockState = "None" | "Waiting" | "Sealing"

export type Objective = { text: string, tip: string?, target: TargetKind? }

export type LevelInput = {
	level: string?,
	airlock: AirlockState,
	insideAirlock: boolean,
	gateSlammed: boolean,
	beyondGate: boolean,
	inVent: boolean,
	roofDoor: string?, -- the run's roof door's DoorState (the housing the route arrives in)
	exitTower: string?, -- the tower of the stairwell the run leaves the level by (nil: the floor's default)
	onRoof: boolean, -- out of the stair housing and the towers
	parachute: string?, -- Player.Parachute (Enums.ParachuteState)
}

export type LobbyInput = {
	phase: string?,
	loaded: boolean,
	inSquad: boolean,
	ready: boolean,
	onBus: boolean,
	voted: boolean,
	perks: boolean,
}

export type OptionalLine = { text: string, done: boolean }
export type LobbyObjective = { text: string, target: TargetKind?, optional: { OptionalLine } }

type View = {
	gui: ScreenGui,
	layer: Frame,
	scale: UIScale,
	tracker: CanvasGroup,
	header: TextLabel,
	keyCap: InputGlyphs.Cap,
	keyLabel: TextLabel,
	line: TextLabel,
	tip: TextLabel,
	optionalRows: { { frame: Frame, box: Frame, label: TextLabel } },
	help: TextButton,
	helpCap: InputGlyphs.Cap,
	card: CanvasGroup,
	cardTitle: TextLabel,
	cardName: TextLabel,
	cardGoal: TextLabel,
	pointer: Frame,
	pointerArrow: Frame,
	pointerLabel: TextLabel,
	marker: BillboardGui,
	markerAnchor: Attachment,
	markerLabel: TextLabel,
	markerDistance: TextLabel,
	markerDiamond: Frame,
}

local SCREEN_ORDER = 19 -- just under the HUD (20): toasts and hints stay on top
local TRACKER_WIDTH = 290
local TRACKER_WIDTH_TOUCH = 250
local TOUCH_TOP = 72
local MARGIN = 14
local POINTER_RADIUS = 92
local MARKER_LIFT = 6.5
local SCAN_SECONDS = 0.25
local STUDS_TO_METERS = 0.28
local FADE_IN = 4
local FADE_OUT = 2.5
local HELP_ACTION = "Rovloc.ObjectiveHelp"
local HELP_KEYS: { Enum.KeyCode } = { Enum.KeyCode.H, Enum.KeyCode.DPadLeft }
local MARKER_SIZE = UDim2.fromOffset(150, 64)
local HIDING_LOCKS: { [string]: boolean } = { Cutscene = true, Jumpscare = true }
local VENT_STATES: { [string]: boolean } = { VentCrawling = true, VentScurrying = true }
local GATE_ID = "HallwayGate"
local ROOF_DOOR_ID = "RoofStairDoor"
local GATE_LEVEL = "Level1_Hallways"
local ROOF_LEVEL = "Level5_Roof"
local POOL_LEVEL = "Level4_FloodedPool"
local ROOF_HOUSING = "L5_RoofAccess"
local BEYOND_MARGIN = 3
local ROWS = 6 -- the lobby's optional lines, or a floor objective's steps and its carried line

local ObjectiveTracker = {}

ObjectiveTracker.Name = "ObjectiveTracker"

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local view: View? = nil
local clock = 0
local scale = 1
local trackerAlpha = 0
local cardAlpha = 0
local pointerAlpha = 0
local markerAlpha = 0
local activeAt = -math.huge -- the tracker shows fully from here for TrackerHold
local lastText: string? = nil
local directionAt = -math.huge -- when the last nudge was asked for
local cardLevel: string? = nil -- the level whose card is due or showing
local cardDueAt = -math.huge
local cardStartedAt: number? = nil
local shownLevel: string? = nil
local scannedAt = -math.huge
local helpBound = false

-- What the last scan found.
local scan = {
	objective = nil :: Objective?,
	lobby = nil :: LobbyObjective?,
	target = nil :: Vector3?,
	inLobby = false,
	title = nil :: string?, -- the floor objective's title (or nil: the objective's own line)
	steps = nil :: { ObjectiveState.StepLine }?,
	carry = nil :: string?,
	label = nil :: string?, -- the nudge's room name
	floor = false, -- the nudge follows the floor objective's timing
	activatedAt = nil :: number?,
}

--------------------------------------------------------------------------------
-- Pure (specs: tests/Specs/Onboarding.spec.luau)
--------------------------------------------------------------------------------

-- The in-run goal for the level state (nil off the levels).
function ObjectiveTracker.levelObjective(input: LevelInput): Objective?
	local level = input.level
	local floor = if level then TutorialConfig.Floors[level] else nil
	if not level or not floor then
		return nil
	end
	local tip = floor.tip
	if input.airlock ~= "None" then
		if input.insideAirlock then
			return { text = "Objective.Airlock.Wait", tip = nil, target = nil }
		end
		return { text = "Objective.Airlock.Get", tip = nil, target = "Exit" }
	end
	if level == ROOF_LEVEL then
		local parachute = input.parachute
		if parachute == "Landed" then
			return { text = "Objective.Roof.Landed", tip = nil, target = nil }
		elseif parachute == "Freefall" then
			return { text = "Objective.Roof.Cord", tip = nil, target = nil }
		elseif parachute == "Canopy" then
			return nil
		elseif parachute == "Packed" then
			return { text = "Objective.Roof.Jump", tip = nil, target = "Gap" }
		elseif input.roofDoor == "Smashed" then
			return { text = "Objective.Roof.Run", tip = tip, target = "Crate" }
		elseif input.onRoof then
			return { text = "Objective.Roof.Search", tip = tip, target = "Crate" }
		end
		return { text = "Objective.Roof.Out", tip = tip, target = "RoofDoor" }
	end
	if level == GATE_LEVEL and input.gateSlammed and not input.beyondGate then
		if input.inVent then
			return { text = "Objective.GateVent", tip = nil, target = nil }
		end
		return { text = "Objective.Gate", tip = tip, target = "BypassVent" }
	end
	if level == POOL_LEVEL then
		return { text = "Objective.PoolStairs", tip = tip, target = "Exit" }
	end
	local tower = input.exitTower or floor.stairwell or "East"
	return { text = "Objective.Stairwell." .. tower, tip = tip, target = "Exit" }
end

-- The lobby's goal: the bus, then a pad, then waiting; the vote and the perks as optional lines.
function ObjectiveTracker.lobbyObjective(input: LobbyInput): LobbyObjective
	local optional: { OptionalLine } = {}
	for _, step in TutorialConfig.LobbySteps do
		if step.optional then
			table.insert(optional, {
				text = step.text,
				done = if step.id == "Vote" then input.voted else input.perks,
			})
		end
	end
	if input.phase == "Countdown" and input.ready then
		return { text = "Objective.Lobby.Countdown", target = nil, optional = {} }
	elseif input.loaded and not input.inSquad then
		return { text = "Objective.Lobby.NextRun", target = nil, optional = optional }
	elseif input.ready then
		return { text = "Objective.Lobby.Waiting", target = nil, optional = optional }
	elseif not input.onBus then
		return { text = "Objective.Lobby.Bus", target = "Bus", optional = optional }
	end
	return { text = "Objective.Lobby.Ready", target = "Pad", optional = optional }
end

-- The tracker's alpha `since` seconds after it was last made active: full for `hold`, then fading over `fade`.
function ObjectiveTracker.trackerAlpha(since: number, hold: number, fade: number): number
	if since <= hold then
		return 1
	end
	return math.clamp(1 - (since - hold) / math.max(fade, 1e-3), 0, 1)
end

-- Whether a nudge asked for at `now` shows (the last one was asked for at `lastAt`), and the seconds of cooldown
-- left otherwise.
function ObjectiveTracker.direction(now: number, lastAt: number, cooldown: number): (boolean, number)
	local remaining = lastAt + cooldown - now
	if remaining <= 0 then
		return true, 0
	end
	return false, remaining
end

-- The Tab nudge's cooldown and the seconds until it is first available: an objective floor waits NudgeDelay after
-- arriving (`activatedAt`, server time) and then cools down NudgeCooldown; anywhere else the tutorial's cooldown.
function ObjectiveTracker.nudgeTiming(
	objectiveFloor: boolean,
	activatedAt: number?,
	serverNow: number
): (number, number)
	if not objectiveFloor then
		return Timing.DirectionCooldown, 0
	end
	local readyAt = if activatedAt then activatedAt + ObjectiveConfig.Tuning.NudgeDelay else serverNow
	return ObjectiveConfig.Tuning.NudgeCooldown, math.max(0, readyAt - serverNow)
end

-- The bearing of `target` from the camera, radians: 0 straight ahead, positive to the right, +-pi behind.
function ObjectiveTracker.bearing(camera: CFrame, target: Vector3): number
	local localPoint = camera:PointToObjectSpace(target)
	if math.abs(localPoint.X) < 1e-6 and math.abs(localPoint.Z) < 1e-6 then
		return 0
	end
	return math.atan2(localPoint.X, -localPoint.Z)
end

-- Whether `point` is past the gate on the way to the exit (more than `margin` studs, horizontally).
function ObjectiveTracker.beyond(gate: Vector3, exit: Vector3, point: Vector3, margin: number): boolean
	local axis = MathUtil.flat(exit - gate)
	if axis.Magnitude < 1e-6 then
		return false
	end
	return MathUtil.flat(point - gate):Dot(axis.Unit) > margin
end

-- The floor card's two lines for a level (Strings keys), or nil off the levels.
function ObjectiveTracker.floorCard(level: string?): (string?, string?)
	local floor = if level then TutorialConfig.Floors[level] else nil
	if not floor then
		return nil, nil
	end
	return floor.title, floor.name
end

-- The floor card's alpha `t` seconds after it started: fade in, hold, fade out (0 once done).
function ObjectiveTracker.floorCardAlpha(t: number): number
	if t < 0 then
		return 0
	elseif t < Timing.FloorCardIn then
		return t / Timing.FloorCardIn
	elseif t < Timing.FloorCardIn + Timing.FloorCardHold then
		return 1
	end
	return math.clamp(1 - (t - Timing.FloorCardIn - Timing.FloorCardHold) / Timing.FloorCardOut, 0, 1)
end

-- Studs as whole metres for the distance readout.
function ObjectiveTracker.meters(studs: number): number
	return math.max(1, math.floor(studs * STUDS_TO_METERS + 0.5))
end

-- The point of `points` nearest `from` (nil for none).
function ObjectiveTracker.nearest(points: { Vector3 }, from: Vector3): Vector3?
	local best: Vector3? = nil
	local bestDistance = math.huge
	for _, point in points do
		local distance = (point - from).Magnitude
		if distance < bestDistance then
			best, bestDistance = point, distance
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- World reads
--------------------------------------------------------------------------------

local function positionOf(instance: Instance): Vector3?
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	elseif instance:IsA("BasePart") then
		return instance.Position
	end
	return nil
end

local function onLevel(instance: Instance, level: string): boolean
	local tagged = instance:GetAttribute(W.LevelId)
	if tagged ~= nil then
		return tagged == level
	end
	local root = Instances.layoutRoot(level)
	if root and instance:IsDescendantOf(root) then
		return true
	end
	local runtime = Instances.runtimeLevel(level, false)
	return runtime ~= nil and instance:IsDescendantOf(runtime)
end

local function scriptedDoor(level: string, id: string): Instance?
	for _, door in CollectionService:GetTagged(Tags.ScriptedDoor) do
		if (door:GetAttribute(W.ScriptedId) == id or door:GetAttribute(W.DoorId) == id) and onLevel(door, level) then
			return door
		end
	end
	return nil
end

local function exitDoors(level: string): { Instance }
	local out: { Instance } = {}
	for _, door in CollectionService:GetTagged(Tags.AirlockDoor) do
		if door:GetAttribute(W.FromLevel) == level and onLevel(door, level) and door:GetAttribute(W.Jammed) ~= true then
			table.insert(out, door)
		end
	end
	return out
end

local function airlockState(doors: { Instance }): AirlockState
	local state: AirlockState = "None"
	for _, door in doors do
		if type(door:GetAttribute(W.StragglerDeadline)) == "number" then
			if door:GetAttribute(W.DoorState) == "Locked" then
				return "Sealing"
			end
			state = "Waiting"
		end
	end
	return state
end

local function insideAirlock(level: string, root: BasePart): boolean
	local exit = AirlockController.exitStairwell(level)
	local room = if exit then exit.fromRoom else nil
	for _, volume in CollectionService:GetTagged(Tags.CheckpointVolume) do
		if
			volume:IsA("BasePart")
			and volume:GetAttribute(W.LevelId) == level
			and (room == nil or volume:GetAttribute(W.ZoneId) == room)
			and SpatialQuery.pointInPart(volume, root.Position)
		then
			return true
		end
	end
	return false
end

local function positions(list: { Instance }, keep: ((Instance) -> boolean)?): { Vector3 }
	local out: { Vector3 } = {}
	for _, instance in list do
		if keep == nil or keep(instance) then
			local position = positionOf(instance)
			if position then
				table.insert(out, position)
			end
		end
	end
	return out
end

local function lobbyBus(): LobbyBuilder.BusInfo?
	return LobbyBuilder.bus(LobbyLayout)
end

local busInfo: LobbyBuilder.BusInfo? = lobbyBus()

local function freePads(userId: number): { Vector3 }
	local lobby = Instances.lobby()
	local props = if lobby then lobby:FindFirstChild(Instances.Names.Props) else nil
	local out: { Vector3 } = {}
	if not props then
		return out
	end
	for _, anchor in LobbyLayout.anchors do
		if anchor.kind == "ReadyPad" then
			local pad = props:FindFirstChild(LobbyBuilder.padName(anchor.id))
			if pad and pad:IsA("BasePart") then
				local occupant = pad:GetAttribute(W.OccupantUserId)
				if occupant == nil or occupant == 0 or occupant == userId then
					table.insert(out, pad.Position)
				end
			end
		end
	end
	return out
end

local function scanLobby(player: Player, root: BasePart?)
	local origin = WorldConfig.levelOrigin("Lobby")
	local bus = busInfo
	local onBus = bus ~= nil and root ~= nil and LobbyBuilder.inBus(bus, root.Position - origin)
	local squad = LobbyController.parseSquad(ReplicatedStorage:GetAttribute(M.LobbySquad))
	local loadout = player:GetAttribute(P.Loadout)
	local stock = player:GetAttribute(P.PerkStock)
	local objective = ObjectiveTracker.lobbyObjective({
		phase = Attributes.getString(ReplicatedStorage, M.MatchPhase, ""),
		loaded = player:GetAttribute(P.DataLoaded) == true,
		inSquad = table.find(squad, player.UserId) ~= nil,
		ready = player:GetAttribute(P.Ready) == true,
		onBus = onBus,
		voted = player:GetAttribute(P.DifficultyVote) ~= nil,
		perks = (type(loadout) == "string" and loadout ~= "") or (type(stock) == "string" and stock ~= ""),
	})
	scan.lobby = objective
	scan.objective = nil
	scan.inLobby = true
	local target: Vector3? = nil
	if objective.target == "Bus" and bus then
		target = origin + bus.entrance
	elseif objective.target == "Pad" and root then
		target = ObjectiveTracker.nearest(freePads(player.UserId), root.Position)
	end
	scan.target = target
end

local function scanLevel(player: Player, level: string, root: BasePart?)
	local doors = exitDoors(level)
	local exitPoint = if root then ObjectiveTracker.nearest(positions(doors), root.Position) else nil
	local gate = if level == GATE_LEVEL then scriptedDoor(level, GATE_ID) else nil
	local gatePoint = if gate then positionOf(gate) else nil
	local gateState = if gate then gate:GetAttribute(W.DoorState) else nil
	local arrival = if level == ROOF_LEVEL then AirlockController.exitStairwell(POOL_LEVEL) else nil
	local roofDoorId = ROOF_DOOR_ID .. (if arrival and arrival.slot ~= "Middle" then arrival.slot else "")
	local roofDoor = if level == ROOF_LEVEL then scriptedDoor(level, roofDoorId) else nil
	local exit = AirlockController.exitStairwell(level)
	local zone = player:GetAttribute(P.ZoneId)
	local moveState = player:GetAttribute(P.MoveState)
	local objective = ObjectiveTracker.levelObjective({
		level = level,
		airlock = airlockState(doors),
		insideAirlock = root ~= nil and insideAirlock(level, root),
		gateSlammed = gateState == "Locked" or gateState == "Closed",
		beyondGate = root ~= nil
			and gatePoint ~= nil
			and exitPoint ~= nil
			and ObjectiveTracker.beyond(gatePoint, exitPoint, root.Position, BEYOND_MARGIN),
		inVent = type(moveState) == "string" and VENT_STATES[moveState] == true,
		roofDoor = if roofDoor then Attributes.getString(roofDoor, W.DoorState, "") else nil,
		exitTower = if exit then exit.tower else nil,
		onRoof = root ~= nil
			and type(zone) == "string"
			and string.sub(zone, 1, #ROOF_HOUSING) ~= ROOF_HOUSING
			and not ParachuteMotion.inTower(root.Position),
		parachute = Attributes.getString(player, P.Parachute, "None"),
	})
	scan.title = nil
	scan.steps = nil
	scan.carry = nil
	scan.label = nil
	scan.floor = false
	scan.activatedAt = nil
	local floorNudge: ObjectiveState.Nudge? = nil
	local spec = ObjectiveConfig.forLevel(level)
	if
		spec
		and objective
		and objective.text ~= "Objective.Airlock.Get"
		and objective.text ~= "Objective.Airlock.Wait"
		and ReplicatedStorage:GetAttribute(M.ObjectiveLevel) == level
	then
		local progress = ObjectiveState.decodeSteps(ReplicatedStorage:GetAttribute(M.ObjectiveSteps))
		local endsAt = ReplicatedStorage:GetAttribute(M.ObjectiveTimerEndsAt)
		local left = if type(endsAt) == "number" then endsAt - Workspace:GetServerTimeNow() else nil
		scan.steps = ObjectiveState.stepLines(spec, progress, left)
		local unlocked = ReplicatedStorage:GetAttribute(M.ObjectiveUnlocked) == true
		if not unlocked then
			scan.title = Strings.get(spec.title)
			scan.carry = ObjectiveState.carryLine(
				ObjectiveState.decodeCarry(player:GetAttribute(P.Carrying)),
				player:GetAttribute(P.HeldItem) == "AcidFlask"
			)
			local activated = ReplicatedStorage:GetAttribute(M.ObjectiveActivatedAt)
			scan.activatedAt = if type(activated) == "number" then activated else nil
			scan.floor = true
			if objective.text == "Objective.Gate" or objective.text == "Objective.GateVent" then
				-- the gate's bypass vent is the way to the objective: say so under the title
				local viaVent: Objective = { text = objective.text, tip = objective.text, target = objective.target }
				objective = viaVent
			else
				local floorGoal: Objective = { text = objective.text, tip = objective.tip, target = "Floor" }
				objective = floorGoal
				local layout = Builder.getLayout(level)
				local targets = ObjectiveState.decodeTargets(ReplicatedStorage:GetAttribute(M.ObjectiveTargets))
				if layout and root then
					floorNudge = ObjectiveState.nudge(layout, targets, root.Position)
				end
			end
		end
	end
	scan.objective = objective
	scan.lobby = nil
	scan.inLobby = false
	local target: Vector3? = nil
	local kind = if objective then objective.target else nil
	if kind == "Floor" then
		local nudge = floorNudge
		if nudge then
			target = nudge.point
			scan.label = nudge.label
		end
	elseif root and kind == "Exit" then
		target = exitPoint
	elseif root and kind == "BypassVent" then
		local grates = positions(CollectionService:GetTagged(Tags.VentGrate), function(grate: Instance): boolean
			return grate:GetAttribute(W.CriticalPath) == true and onLevel(grate, level)
		end)
		local near: { Vector3 } = {}
		for _, point in grates do
			if
				not (gatePoint and exitPoint and ObjectiveTracker.beyond(gatePoint, exitPoint, point, BEYOND_MARGIN))
			then
				table.insert(near, point)
			end
		end
		target = ObjectiveTracker.nearest(if #near > 0 then near else grates, root.Position)
	elseif kind == "RoofDoor" and roofDoor then
		target = positionOf(roofDoor)
	elseif root and kind == "Crate" then
		target = ObjectiveTracker.nearest(
			positions(CollectionService:GetTagged(Tags.ParachutePack), function(pack: Instance): boolean
				local taken = pack:GetAttribute(W.TakenByUserId)
				return (taken == nil or taken == 0) and onLevel(pack, level)
			end),
			root.Position
		)
	elseif kind == "Gap" then
		local gap = ParachuteMotion.Gap
		target = Vector3.new((gap.minX + gap.maxX) / 2, ParachuteMotion.DeckY + 3, (gap.minZ + gap.maxZ) / 2)
	end
	scan.target = target
end

local function rescan()
	scannedAt = clock
	local player = localPlayer
	if not player then
		return
	end
	local root = Instances.characterRoot(player)
	local phase = ReplicatedStorage:GetAttribute(M.MatchPhase)
	local lifeState = player:GetAttribute(P.LifeState)
	if (phase == "Lobby" or phase == "Countdown") and lifeState ~= "Alive" and lifeState ~= "Downed" then
		scanLobby(player, root)
		return
	end
	local level = ReplicatedStorage:GetAttribute(M.CurrentLevel)
	if (phase == "InRun" or phase == "Deploying") and type(level) == "string" and lifeState == "Alive" then
		scanLevel(player, level, root)
		return
	end
	scan.objective = nil
	scan.lobby = nil
	scan.target = nil
	scan.inLobby = false
	scan.title = nil
	scan.steps = nil
	scan.carry = nil
	scan.label = nil
	scan.floor = false
end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

local function build(parent: Instance): View
	local gui = UIKit.screenGui("Objective", SCREEN_ORDER, Enum.ScreenInsets.CoreUISafeInsets)
	local layer = UIKit.frame(gui, "Layer")
	local layerScale = Instance.new("UIScale")
	layerScale.Parent = layer

	-- Tracker
	local tracker = Instance.new("CanvasGroup")
	tracker.Name = "Tracker"
	tracker.BackgroundTransparency = 1
	tracker.BorderSizePixel = 0
	tracker.Position = UDim2.fromOffset(MARGIN, MARGIN)
	tracker.Size = UDim2.fromOffset(TRACKER_WIDTH, 0)
	tracker.AutomaticSize = Enum.AutomaticSize.Y
	tracker.GroupTransparency = 1
	tracker.Parent = layer
	local sheet = UIKit.panel(tracker, "Sheet", 0.28, 7411)
	sheet.Size = UDim2.fromScale(1, 0)
	sheet.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.padding(sheet, 12, 9)
	UIKit.list(sheet, Enum.FillDirection.Vertical, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top)
	local edge = UIKit.fill(tracker, "Edge", Palette.Amber, 0.2)
	edge.Size = UDim2.new(0, 2, 1, -8)
	edge.Position = UDim2.fromOffset(0, 4)
	edge.ZIndex = 2

	local headerRow = UIKit.frame(sheet, "HeaderRow")
	headerRow.LayoutOrder = 1
	headerRow.Size = UDim2.new(1, 0, 0, 20)
	local header = UIKit.label(headerRow, "Header", UIKit.Fonts.Heavy, UIKit.TextSize.Caps, Palette.Amber)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.TextWrapped = false
	header.Text = Strings.get("Objective.Header")
	local keyRow = UIKit.frame(headerRow, "Key")
	keyRow.AnchorPoint = Vector2.new(1, 0)
	keyRow.Position = UDim2.fromScale(1, 0)
	keyRow.Size = UDim2.new(0.6, 0, 1, 0)
	UIKit.list(keyRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	local keyCap = InputGlyphs.cap(keyRow, "Cap", 18)
	keyCap.root.LayoutOrder = 1
	local keyLabel = UIKit.label(keyRow, "Label", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Ash)
	keyLabel.LayoutOrder = 2
	keyLabel.AutomaticSize = Enum.AutomaticSize.X
	keyLabel.Size = UDim2.fromScale(0, 1)
	keyLabel.TextWrapped = false

	local line = UIKit.label(sheet, "Line", UIKit.Fonts.Title, UIKit.TextSize.Hint - 1, Palette.Bone)
	line.LayoutOrder = 2
	line.Size = UDim2.fromScale(1, 0)
	line.AutomaticSize = Enum.AutomaticSize.Y
	line.TextXAlignment = Enum.TextXAlignment.Left
	UIKit.textStroke(line, 0.45)
	local tip = UIKit.label(sheet, "Tip", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Ash)
	tip.LayoutOrder = 3
	tip.Size = UDim2.fromScale(1, 0)
	tip.AutomaticSize = Enum.AutomaticSize.Y
	tip.TextXAlignment = Enum.TextXAlignment.Left

	local optionalRows: { { frame: Frame, box: Frame, label: TextLabel } } = {}
	for index = 1, ROWS do
		local row = UIKit.frame(sheet, "Optional" .. index)
		row.LayoutOrder = 3 + index
		row.Size = UDim2.new(1, 0, 0, 18)
		local box = UIKit.fill(row, "Box", Palette.Ink, 0.3)
		box.AnchorPoint = Vector2.new(0, 0.5)
		box.Position = UDim2.fromScale(0, 0.5)
		box.Size = UDim2.fromOffset(10, 10)
		UIKit.corner(box, UDim.new(0, 2))
		UIKit.stroke(box, Palette.Ash, 1, 0.2)
		local label = UIKit.label(row, "Text", UIKit.Fonts.Body, UIKit.TextSize.Small, Palette.Ash)
		label.Position = UDim2.fromOffset(18, 0)
		label.Size = UDim2.new(1, -18, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextWrapped = false
		label.TextTruncate = Enum.TextTruncate.AtEnd
		row.Visible = false
		table.insert(optionalRows, { frame = row, box = box, label = label })
	end

	local help = Instance.new("TextButton")
	help.Name = "Help"
	help.LayoutOrder = 10
	help.Size = UDim2.new(1, 0, 0, UIKit.MinTouchTarget)
	help.BackgroundColor3 = Palette.Raised
	help.BackgroundTransparency = 0.15
	help.BorderSizePixel = 0
	help.AutoButtonColor = true
	help.Text = ""
	help.Visible = false
	help.Parent = sheet
	UIKit.corner(help, UDim.new(0, 5))
	UIKit.stroke(help, Palette.StrokeDim, 1, 0)
	UIKit.list(help, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	local mark = UIKit.label(help, "Mark", UIKit.Fonts.Heavy, UIKit.TextSize.Body, Palette.Amber)
	mark.LayoutOrder = 1
	mark.Size = UDim2.fromOffset(22, 22)
	mark.Text = Strings.get("Lobby.HelpMark")
	UIKit.round(mark)
	UIKit.stroke(mark, Palette.Amber, 1.5, 0.1)
	local helpText = UIKit.label(help, "Text", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Bone)
	helpText.LayoutOrder = 2
	helpText.AutomaticSize = Enum.AutomaticSize.X
	helpText.Size = UDim2.fromScale(0, 1)
	helpText.TextWrapped = false
	helpText.Text = Strings.get("Lobby.Help")
	local helpCap = InputGlyphs.cap(help, "Cap", 20)
	helpCap.root.LayoutOrder = 3

	-- Floor card
	local card = Instance.new("CanvasGroup")
	card.Name = "FloorCard"
	card.BackgroundTransparency = 1
	card.BorderSizePixel = 0
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.3)
	card.Size = UDim2.fromOffset(520, 130)
	card.GroupTransparency = 1
	card.Visible = false
	card.Parent = layer
	local wash = UIKit.fill(card, "Wash", Palette.Ink, 0.35)
	UIKit.gradient(wash, 0, { { 0, 1 }, { 0.25, 0.3 }, { 0.75, 0.3 }, { 1, 1 } })
	local cardTitle = UIKit.label(card, "Title", UIKit.Fonts.Title, 46, Palette.Bone)
	cardTitle.Size = UDim2.new(1, 0, 0, 58)
	cardTitle.Position = UDim2.fromOffset(0, 8)
	cardTitle.TextWrapped = false
	UIKit.textStroke(cardTitle, 0.3)
	local rule = UIKit.fill(card, "Rule", Palette.Blood, 0.1)
	rule.AnchorPoint = Vector2.new(0.5, 0)
	rule.Position = UDim2.new(0.5, 0, 0, 70)
	rule.Size = UDim2.fromOffset(240, 2)
	UIKit.gradient(rule, 0, { { 0, 1 }, { 0.5, 0 }, { 1, 1 } })
	local cardName = UIKit.label(card, "Name", UIKit.Fonts.Strong, UIKit.TextSize.Body + 1, Palette.Ash)
	cardName.Size = UDim2.new(1, 0, 0, 24)
	cardName.Position = UDim2.fromOffset(0, 78)
	cardName.TextWrapped = false
	local cardGoal = UIKit.label(card, "Goal", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Amber)
	cardGoal.Size = UDim2.new(1, 0, 0, 20)
	cardGoal.Position = UDim2.fromOffset(0, 104)
	cardGoal.TextWrapped = false
	cardGoal.Text = ""

	-- Direction pointer around the crosshair
	local pointer = UIKit.frame(layer, "Pointer")
	pointer.AnchorPoint = Vector2.new(0.5, 0.5)
	pointer.Position = UDim2.fromScale(0.5, 0.5)
	pointer.Size = UDim2.fromOffset(POINTER_RADIUS * 2, POINTER_RADIUS * 2)
	pointer.Visible = false
	local pointerArrow = UIKit.frame(pointer, "Arrow")
	pointerArrow.AnchorPoint = Vector2.new(0.5, 0.5)
	pointerArrow.Size = UDim2.fromOffset(28, 28)
	for index, side in { -1, 1 } do
		local arm = UIKit.fill(pointerArrow, "Arm" .. index, Palette.Amber, 0.05)
		arm.AnchorPoint = Vector2.new(0.5, 0)
		arm.Position = UDim2.new(0.5, side * 5, 0, 2)
		arm.Size = UDim2.fromOffset(4, 16)
		arm.Rotation = side * 38
		UIKit.corner(arm, UDim.new(0.5, 0))
	end
	local pointerLabel = UIKit.label(pointer, "Distance", UIKit.Fonts.Strong, UIKit.TextSize.Small, Palette.Bone)
	pointerLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	pointerLabel.Size = UDim2.fromOffset(80, 18)
	pointerLabel.TextWrapped = false
	UIKit.textStroke(pointerLabel, 0.4)

	-- World marker
	local markerAnchor = Instance.new("Attachment")
	markerAnchor.Name = "ObjectiveMarker"
	markerAnchor.Parent = Workspace.Terrain
	local marker = Instance.new("BillboardGui")
	marker.Name = "ObjectiveMarker"
	marker.AlwaysOnTop = true
	marker.LightInfluence = 0
	marker.Size = MARKER_SIZE
	marker.MaxDistance = 500
	marker.ResetOnSpawn = false
	marker.Adornee = markerAnchor
	marker.Enabled = false
	local markerDiamond = UIKit.fill(marker, "Diamond", Palette.Ink, 0.35)
	markerDiamond.AnchorPoint = Vector2.new(0.5, 0)
	markerDiamond.Position = UDim2.new(0.5, 0, 0, 2)
	markerDiamond.Size = UDim2.fromOffset(16, 16)
	markerDiamond.Rotation = 45
	UIKit.stroke(markerDiamond, Palette.Amber, 2, 0)
	local markerLabel = UIKit.label(marker, "Label", UIKit.Fonts.Heavy, UIKit.TextSize.Small, Palette.Amber)
	markerLabel.Position = UDim2.fromOffset(0, 24)
	markerLabel.Size = UDim2.new(1, 0, 0, 18)
	markerLabel.TextWrapped = false
	UIKit.textStroke(markerLabel, 0.3)
	local markerDistance = UIKit.label(marker, "Distance", UIKit.Fonts.Strong, UIKit.TextSize.Caps, Palette.Bone)
	markerDistance.Position = UDim2.fromOffset(0, 42)
	markerDistance.Size = UDim2.new(1, 0, 0, 16)
	markerDistance.TextWrapped = false
	UIKit.textStroke(markerDistance, 0.3)
	marker.Parent = parent

	gui.Parent = parent
	return {
		gui = gui,
		layer = layer,
		scale = layerScale,
		tracker = tracker,
		header = header,
		keyCap = keyCap,
		keyLabel = keyLabel,
		line = line,
		tip = tip,
		optionalRows = optionalRows,
		help = help,
		helpCap = helpCap,
		card = card,
		cardTitle = cardTitle,
		cardName = cardName,
		cardGoal = cardGoal,
		pointer = pointer,
		pointerArrow = pointerArrow,
		pointerLabel = pointerLabel,
		marker = marker,
		markerAnchor = markerAnchor,
		markerLabel = markerLabel,
		markerDistance = markerDistance,
		markerDiamond = markerDiamond,
	}
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function allowed(): boolean
	local player = localPlayer
	if not player or not HUD.IsVisible() or OnboardingController.IsBusy() then
		return false
	end
	local context = InputController.GetContext()
	if context == "Cutscene" or context == "Menu" then
		return false
	end
	return not HIDING_LOCKS[Attributes.getString(player, P.ControlLock, "None")]
end

local function helpPressed()
	if scan.inLobby and allowed() then
		OnboardingController.OpenWalkthrough()
	end
end

local function onHelpKey(_action: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		helpPressed()
	end
	return Enum.ContextActionResult.Sink
end

local function bindHelp(on: boolean)
	if on == helpBound then
		return
	end
	helpBound = on
	if on then
		ContextActionService:BindActionAtPriority(
			HELP_ACTION,
			onHelpKey,
			false,
			InputConfig.ActionPriority + 1,
			table.unpack(HELP_KEYS)
		)
	else
		ContextActionService:UnbindAction(HELP_ACTION)
	end
end

local function onObjective(phase: string)
	if phase ~= "Begin" or not allowed() then
		return
	end
	activeAt = clock
	local cooldown, wait = ObjectiveTracker.nudgeTiming(scan.floor, scan.activatedAt, Workspace:GetServerTimeNow())
	local ready = ObjectiveTracker.direction(clock, directionAt, cooldown)
	if ready and wait <= 0 and scan.target then
		directionAt = clock
		xpcall(function()
			AudioController.PlayLocal("UiClick")
		end, function(err: any)
			log.warnThrottled("sound", 60, "ui sound failed: %s", tostring(err))
		end)
	end
end

local function markerText(kind: TargetKind?): string
	if kind == "Bus" then
		return Strings.get("Objective.Marker.Bus")
	elseif kind == "Pad" then
		return Strings.get("Objective.Marker.Pad")
	end
	return Strings.get("Objective.Marker.Goal")
end

local function updateCard(current: View, dt: number, canShow: boolean)
	local phase = ReplicatedStorage:GetAttribute(M.MatchPhase)
	local level = ReplicatedStorage:GetAttribute(M.CurrentLevel)
	local inRun = phase == "InRun" or phase == "Deploying"
	if inRun and type(level) == "string" and level ~= shownLevel then
		shownLevel = level
		cardLevel = level
		cardDueAt = clock
		cardStartedAt = nil
		activeAt = clock
	elseif not inRun then
		shownLevel = nil
	end
	local due = cardLevel
	if due and cardStartedAt == nil then
		if canShow then
			local titleKey, nameKey = ObjectiveTracker.floorCard(due)
			if titleKey and nameKey then
				current.cardTitle.Text = Strings.get(titleKey)
				current.cardName.Text = Strings.get(nameKey)
				local spec = ObjectiveConfig.forLevel(due)
				current.cardGoal.Text = if spec then Strings.get("Obj.Card", Strings.get(spec.title)) else ""
				cardStartedAt = clock
			else
				cardLevel = nil
			end
		elseif clock - cardDueAt > Timing.FloorCardWait then
			cardLevel = nil
		end
	end
	local started = cardStartedAt
	local target = 0
	if started then
		target = ObjectiveTracker.floorCardAlpha(clock - started)
		if clock - started > Timing.FloorCardIn + Timing.FloorCardHold + Timing.FloorCardOut then
			cardStartedAt = nil
			cardLevel = nil
		end
	end
	if not canShow then
		target = 0
	end
	cardAlpha = MathUtil.approach(cardAlpha, target, dt * FADE_IN)
	current.card.Visible = cardAlpha > 0.001
	current.card.GroupTransparency = 1 - cardAlpha
end

local function step(dt: number)
	local current = view
	if not current then
		return
	end
	clock += dt
	if clock - scannedAt >= SCAN_SECONDS then
		rescan()
	end
	local camera = Workspace.CurrentCamera
	local nextScale = if camera then UIKit.scaleFor(camera.ViewportSize) else 1
	if math.abs(nextScale - scale) > 1e-3 then
		scale = nextScale
		current.scale.Scale = scale
		current.layer.Size = UDim2.fromScale(1 / scale, 1 / scale)
	end
	local canShow = allowed()
	updateCard(current, dt, canShow)

	local device = InputController.GetDevice()
	local touch = device == "Touch"
	current.tracker.AnchorPoint = if touch then Vector2.new(1, 0) else Vector2.zero
	current.tracker.Position = if touch then UDim2.new(1, -MARGIN, 0, TOUCH_TOP) else UDim2.fromOffset(MARGIN, MARGIN)
	current.tracker.Size = UDim2.fromOffset(if touch then TRACKER_WIDTH_TOUCH else TRACKER_WIDTH, 0)

	-- What the tracker says
	local text: string? = nil
	local tipKey: string? = nil
	local lobby = scan.lobby
	local objective = scan.objective
	if lobby then
		text = lobby.text
	elseif objective then
		text = objective.text
		tipKey = objective.tip
	end
	local steps = if lobby then nil else scan.steps
	local title = if lobby then nil else scan.title
	-- a new goal, or a step changing (a count, a tick), brings the tracker back; so does a running countdown
	local shown = (title or text or "") .. "#"
	local stepList: { ObjectiveState.StepLine } = steps or {}
	for _, stepLine in stepList do
		shown ..= (if stepLine.done then "1" else "0") .. (if stepLine.timed then "" else stepLine.text) .. "|"
		if stepLine.timed and stepLine.active then
			activeAt = clock
		end
	end
	if shown ~= lastText then
		lastText = shown
		activeAt = clock
	end
	if title or text then
		local line = if title then title else Strings.get(text :: string)
		if current.line.Text ~= line then
			current.line.Text = line
		end
	end
	current.tip.Text = if tipKey then Strings.get(tipKey) else ""
	current.tip.Visible = tipKey ~= nil
	local carryLine = if lobby then nil else scan.carry
	for index, row in current.optionalRows do
		local entry = if lobby then lobby.optional[index] else nil
		local stepLine = if steps then steps[index] else nil
		local carryRow = steps ~= nil and carryLine ~= nil and index == #steps + 1
		row.frame.Visible = entry ~= nil or stepLine ~= nil or carryRow
		row.box.Visible = not carryRow
		if entry then
			row.label.Text = Strings.get(entry.text)
			row.label.TextColor3 = if entry.done then Palette.Moss else Palette.Ash
			row.box.BackgroundColor3 = if entry.done then Palette.Moss else Palette.Ink
		elseif stepLine then
			row.label.Text = stepLine.text
			row.label.TextColor3 = if stepLine.done
				then Palette.Moss
				elseif stepLine.active then Palette.Bone
				else Palette.Ash
			row.box.BackgroundColor3 = if stepLine.done then Palette.Moss else Palette.Ink
		elseif carryRow then
			row.label.Text = carryLine :: string
			row.label.TextColor3 = Palette.Amber
		end
	end
	current.help.Visible = scan.inLobby
	bindHelp(scan.inLobby and canShow)
	current.helpCap.root.Visible = not touch
	if not touch then
		current.helpCap:SetGlyph(
			if device == "Gamepad"
				then { kind = "Gamepad", keyCode = HELP_KEYS[2] }
				else { kind = "Keyboard", keyCode = HELP_KEYS[1] }
		)
	end

	local cooldown, wait = ObjectiveTracker.nudgeTiming(scan.floor, scan.activatedAt, Workspace:GetServerTimeNow())
	local readyNow, remaining = ObjectiveTracker.direction(clock, directionAt, cooldown)
	if wait > 0 then
		readyNow, remaining = false, math.max(remaining, wait)
	end
	current.keyCap:SetGlyph(InputGlyphs.forAction("Objective", device))
	current.keyLabel.Text = if readyNow
		then Strings.get("Objective.Direction")
		else Strings.get("Objective.DirectionWait", math.ceil(remaining))
	current.keyCap.root.Visible = scan.target ~= nil
	current.keyLabel.Visible = scan.target ~= nil

	local trackerTarget = 0
	if (text or title) and canShow then
		trackerTarget = if scan.inLobby
			then 1
			else ObjectiveTracker.trackerAlpha(clock - activeAt, Timing.TrackerHold, Timing.TrackerFade)
	end
	trackerAlpha = MathUtil.approach(
		trackerAlpha,
		trackerTarget,
		dt * (if trackerTarget > trackerAlpha then FADE_IN else FADE_OUT)
	)
	current.tracker.Visible = trackerAlpha > 0.001
	current.tracker.GroupTransparency = 1 - trackerAlpha

	-- Direction nudge and marker
	local target = scan.target
	local nudging = canShow and target ~= nil and clock - directionAt <= Timing.DirectionShow
	local pointerTarget = if nudging and not scan.inLobby then 1 else 0
	pointerAlpha = MathUtil.approach(pointerAlpha, pointerTarget, dt * FADE_IN)
	current.pointer.Visible = pointerAlpha > 0.001 and target ~= nil and camera ~= nil
	local player = localPlayer
	local root = if player then Instances.characterRoot(player) else nil
	local distance = if target and root then (target - root.Position).Magnitude else 0
	if current.pointer.Visible and target and camera then
		local angle = ObjectiveTracker.bearing(camera.CFrame, target)
		local x, y = math.sin(angle) * POINTER_RADIUS, -math.cos(angle) * POINTER_RADIUS
		current.pointerArrow.Position = UDim2.new(0.5, x, 0.5, y)
		current.pointerArrow.Rotation = math.deg(angle)
		current.pointerLabel.Position = UDim2.new(0.5, x * 0.62, 0.5, y * 0.62)
		local far = Strings.get("Objective.Distance", ObjectiveTracker.meters(distance))
		local room = scan.label
		current.pointerLabel.Text = if room then Strings.get("Obj.Nudge", room, far) else far
		local fade = 1 - pointerAlpha
		for _, arm in current.pointerArrow:GetChildren() do
			if arm:IsA("Frame") then
				arm.BackgroundTransparency = UIKit.fade(0.05, pointerAlpha)
			end
		end
		current.pointerLabel.TextTransparency = fade
	end

	local markerTarget = 0
	if canShow and target then
		if scan.inLobby then
			markerTarget = 1
		elseif nudging then
			markerTarget = 0.85
		end
	end
	markerAlpha = MathUtil.approach(markerAlpha, markerTarget, dt * FADE_IN)
	current.marker.Enabled = markerAlpha > 0.001 and target ~= nil
	if current.marker.Enabled and target then
		local bob = math.sin(clock * 2.2) * 0.35
		current.markerAnchor.WorldPosition = target + Vector3.new(0, MARKER_LIFT + bob, 0)
		local kind: TargetKind? = if lobby then lobby.target elseif objective then objective.target else nil
		current.markerLabel.Text = scan.label or markerText(kind)
		current.markerDistance.Text = Strings.get("Objective.Distance", ObjectiveTracker.meters(distance))
		local pulse = 0.5 + 0.5 * math.sin(clock * 3)
		current.markerLabel.TextTransparency = UIKit.fade(0, markerAlpha)
		current.markerDistance.TextTransparency = UIKit.fade(0.2, markerAlpha)
		current.markerDiamond.BackgroundTransparency = UIKit.fade(0.35 + 0.2 * pulse, markerAlpha)
		local stroke = current.markerDiamond:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = UIKit.fade(0, markerAlpha)
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- How much of the tracker sheet shows (0 hidden .. 1 shown) and whether it sits top-right (touch): SquadPanel shares
-- that corner on touch and keeps out of the sheet's way.
function ObjectiveTracker.GetTrackerAlpha(): (number, boolean)
	return trackerAlpha, InputController.GetDevice() == "Touch"
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ObjectiveTracker.Init() end

function ObjectiveTracker.Start()
	local player = localPlayer
	if not player then
		return
	end
	local gui = player:WaitForChild("PlayerGui")
	local ok = xpcall(function()
		view = build(gui)
	end, function(err: any)
		log.error("objective tracker failed to mount: %s\n%s", tostring(err), debug.traceback())
	end)
	local current = view
	if not ok or not current then
		return
	end
	serviceTrove:Add(current.gui)
	serviceTrove:Add(current.marker)
	serviceTrove:Add(current.markerAnchor)
	serviceTrove:Connect(current.help.Activated, helpPressed)
	serviceTrove:Add(InputController.Action("Objective"):Connect(onObjective))
	serviceTrove:Connect(RunService.PreRender, function(dt: number)
		xpcall(step, function(err: any)
			log.warnThrottled("step", 10, "objective step failed: %s\n%s", tostring(err), debug.traceback())
		end, dt)
	end)
end

function ObjectiveTracker.OnRunStarted(_info: Types.RunInfo)
	directionAt = -math.huge
	activeAt = clock
	shownLevel = nil
	scannedAt = -math.huge
end

function ObjectiveTracker.OnRunEnded()
	cardLevel = nil
	cardStartedAt = nil
	shownLevel = nil
	scannedAt = -math.huge
	bindHelp(false)
end

return table.freeze(ObjectiveTracker)
