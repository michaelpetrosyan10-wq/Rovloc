--!strict
-- VentController: crawling the ducts, on this client. The server decides who is inside (VentNetworkService puts a
-- crouching player through an open grate: Vent collision mode, Vent locomotion mode and a teleport onto the duct
-- centreline; the exit teleport takes them out again); this controller drives the crawl in between. The client owns
-- its character, so the crawl is local physics the server only validates (MovementAuthority's rail validator).
--
-- Membership (membership, pure). A session starts when the replicated MoveState becomes VentCrawling or
-- VentScurrying and ends the moment the server's MoveState leaves the duct (an on-foot or swimming state), the
-- character dies or is replaced, or the run ends. An override state while the server still holds the character in
-- Vent collision (DownedCrawling in a duct, a Grabbed / Scripted hold) keeps the session, so a downed player drags
-- along the rail at DownedMoveSpeed instead of the Humanoid trying to stand up inside the bore. While a ControlLock is
-- held (or the root is anchored) the session lets go of the body and the server moves it; afterwards the cursor
-- snaps to wherever the server left it.
--
-- Engaging: the level's VentGraph (cached per level: the CurrentLevel, the player's LevelId, else the level whose
-- rail passes closest), InputContext "Vent" (sprint scurries; crouch is not live), FirstPersonController
-- SuspendBodyYaw + SetMoveModeHint("Vent"), AudioController.SetEnvironmentOverride("Vent"), and on the own root an
-- Attachment with a client-made AlignPosition (OneAttachment, Responsiveness 200, MaxForce 1e7, applied at the centre
-- of mass) and AlignOrientation (OneAttachment, all axes: nothing else keeps the body upright). The Humanoid goes to
-- Physics with every state it could leave Physics for disabled (saved and restored exactly on release), so it never
-- fights the constraints. In Vent collision only the welded VentCollider ball collides, and the rail keeps it on the
-- bore's centreline, 0.45 studs clear of every duct wall.
--
-- The rail cursor ({ a, b, t }: t is the fraction from node a to node b, or along node a's grate mouth stub when b
-- is nil) is snapped from VentGraph.nearest. Every PreSimulation:
--   * Server moves. A root that jumped further than JUMP_DISTANCE from where it was and from the cursor was moved by
--     the server (serverMove, pure): onto the rail (a MovementAuthority correction) the cursor re-snaps there; off it
--     (the exit teleport) the body is held where it landed until the MoveState confirms the exit. Entering is the same
--     hold: until the entry teleport lands on the rail (ENTRY_WAIT at most) nothing pulls the body anywhere.
--   * Direction (travel, pure). Input is Humanoid.MoveDirection (camera relative, flat). The heading along the
--     current duct is the one whose rail tangent best matches it (dot >= MIN_TRAVEL_DOT; forward = the camera look
--     flattened onto the tangent, backward allowed), and a junction within LOOKAHEAD counts the branch the input
--     points down, so looking into a side duct carries you to the junction and into it. Bends are rounded: within
--     ROUND_RADIUS of a node with one way on, the tangent blends toward that way, so holding forward follows the duct
--     round a corner instead of stopping against its wall. Speed: the predicted MoveState's WalkSpeed (crawlSpeed:
--     VentCrawlSpeed / VentScurrySpeed / DownedMoveSpeed, MovementController's table) times the input's strength,
--     reached over ACCEL_TIME and shed over DECEL_TIME; a reversal brakes to a stop first (stepSpeed, pure).
--   * Advance (advance, pure). The cursor moves along the duct; at a node with one way on it follows the duct; at a
--     junction it takes the way most aligned with the input (dot >= MIN_TRAVEL_DOT), or stops (looking at a wall).
--     Dead ends stop it. A shut grate (Closed / Unscrewing / Locked) stops the ball PANEL_MARGIN short of the panel:
--     the stop is measured with a ball-sized Spherecast against that grate's model once its panel has settled shut
--     (PANEL_SETTLE; until then the wall's room face is assumed) and kept until its GrateState changes (panelStop), so
--     the eye ends up just behind the louvres. An open (Open / Kicked) grate's mouth stub carries you out to the mouth,
--     past the room face, where the server's exit takes over. A grate that shuts on a crawler pushes the cursor back
--     out of its keep-out (encroachment, pure).
--   * Leash. The cursor never runs more than LEASH ahead of the root; a root held back for STUCK_SECONDS (something
--     unexpected in the bore) re-snaps the cursor to it instead of pulling harder.
--   * Facing (chooseFacing / smoothYaw, pure). The body lies along the duct facing the tangent direction nearest
--     the camera look (with hysteresis, so looking at a side wall never flips it), turned at most MAX_TURN_RATE with
--     an exponential ease: round corners it pivots with the duct, and crawling backward keeps facing the look.
--     Target CFrame = rail point (the root on the centreline) at that yaw.
-- Presentation: a dark procedural vignette (ScreenGui of gradient edge frames, no images) fades in while inside and
-- tightens while scurrying; a looped local VentCrawl (crawl, and a faster scurry voice crossfaded in) follows the rail
-- speed; sheet-metal knocks (a pitched VentCrawl hit + a small shake) land on reversals, corners and bumping a stop;
-- every hand plant of the crawl (the local Animator's gait phase crossing 0 / 0.5) gives the camera a small jolt.
-- Release (exit, leaving, death, respawn, run end): constraints destroyed, Humanoid states restored (GettingUp when
-- it was still in Physics), body yaw resumed, hint, input context and acoustics cleared, loops faded, vignette out.
--
-- Pure maths (tests/Specs/VentController.spec.luau): span, position, fromRailPoint, ways, tangent, travel,
-- chooseBranch, advance, encroachment, panelStop, chooseFacing, smoothYaw, stepSpeed, membership, colliderMode,
-- serverMove, crawlSpeed, crawlVolume, vignette, plantCrossed, isPassable.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local CollisionGroups = require(ReplicatedStorage.Shared.CollisionGroups)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local ProceduralAnimator = require(ReplicatedStorage.Shared.Animation.ProceduralAnimator)
local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local InputController = require(Controllers.Core.InputController)
local CharacterAnimationController = require(Controllers.Characters.CharacterAnimationController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)

local log = Log.new("VentClient")

local P = Attributes.Player
local W = Attributes.World
local M = Attributes.Match

export type Cursor = { a: string, b: string?, t: number }

-- One way out of a node: toward neighbour `b`, or along `a`'s grate mouth stub when `b` is nil.
export type Way = { a: string, b: string?, direction: Vector3, blocked: boolean }

-- The rail as the pure functions see it: the graph plus the live grate rules.
export type Rail = {
	graph: VentGraph.Graph,
	passable: (grateId: string) -> boolean, -- Open / Kicked
	stopShort: (grateId: string) -> number, -- studs before a shut grate's node the ball must stop
}

export type StopReason = "DeadEnd" | "Blocked" | "Mouth" | "Junction"

export type Step = {
	cursor: Cursor,
	heading: number, -- +1 toward cursor.b (or the mouth), -1 toward cursor.a, after the move
	travelled: number,
	stopped: StopReason?,
	turned: number, -- largest turn (radians) taken at a node on the way
}

export type Membership = "Idle" | "Engage" | "Drive" | "Hold" | "Release"
export type ColliderMode = "Vent" | "Locked" | "Normal"
export type ServerMove = "None" | "Resnap" | "Hold"

export type MembershipInput = {
	engaged: boolean,
	alive: boolean,
	moveState: string,
	collider: ColliderMode,
	locked: boolean,
}

local TOKEN = "Vent"
local VENT_CONTEXT: Enums.InputContext = "Vent"
local VENT_ACOUSTICS: Enums.AcousticPreset = "Vent"
local CONSTRAINT_NAME = "VentRail"
local VENT_COLLIDER_NAME = "VentCollider" -- CharacterService's welded ball (CollisionService.VentColliderName)
local CRAWL_PRESET = "VentCrawl"
local VIGNETTE_NAME = "VentVignette"

-- Geometry
local BALL_RADIUS = WorldConfig.VentColliderDiameter / 2
local PANEL_MARGIN = 0.08 -- studs between the ball and a shut grate's panel
local PANEL_FALLBACK = WorldConfig.WallThickness / 2 -- assumed panel face (the wall's room face) when unmeasured
local PANEL_SETTLE = 1 -- seconds a grate must stay shut before its panel is measured (it swings shut)
local PROBE_BACK = BALL_RADIUS + 2 -- the panel probe starts this far behind the wall plane
local PROBE_REACH = 6
local ROUND_RADIUS = WorldConfig.VentBore / 2 -- bends are rounded this far either side of the node
local LOOKAHEAD = WorldConfig.VentBore / 2 -- a junction this close counts the branch the input points down
local MAX_HOPS = 8

-- Input and speed
local MIN_TRAVEL_DOT = 0.2 -- below this the input does not point along the rail (or down a branch)
local FULL_TRAVEL_DOT = 0.45 -- from here the input drives at full strength
local INPUT_DEADZONE = 0.1
local PREFER_BONUS = 0.05 -- the current heading wins ties (no flip-flop between equal choices)
local ACCEL_TIME = 0.14 -- seconds from rest to full speed
local DECEL_TIME = 0.09
local SPEED_EPSILON = 1e-3

-- Facing
local FACING_SPEED = 10 -- 1/s exponential ease toward the duct direction
local MAX_TURN_RATE = 7 -- rad/s (a 90 degree corner in about a quarter second)
local FACING_HYSTERESIS = 0.35 -- the camera must look ~110 degrees off the body before it turns round

-- Server moves, holds, leash
local JUMP_DISTANCE = 2.5 -- a root jump this large (from the last frame and from the cursor) was the server's
local ON_RAIL = 0.75 -- a root this close to the rail is on it
local ENGAGE_RADIUS = 4 -- a rail point this close is the one we are in (MovementAuthority corrects within 4)
local ENTRY_WAIT = 1 -- seconds the session waits for the entry teleport before snapping to the nearest rail point
local HOLD_TIMEOUT = 1.5 -- seconds an off-rail server move is held waiting for the exit to confirm
local GRAPH_RETRY = 0.5
local LEASH = 0.75
local STUCK_SECONDS = 0.6

-- Constraints
local ALIGN_RESPONSIVENESS = 200
local ALIGN_MAX_FORCE = 1e7
local ALIGN_MAX_VELOCITY = GameConfig.VentScurrySpeed * 4
local ORIENT_RESPONSIVENESS = 120
local ORIENT_MAX_TORQUE = 1e7
local ORIENT_MAX_ANGULAR = 30
local MAX_DT = 0.1

-- Audio and camera
local CRAWL_LOOP_VOLUME = 0.5
local SCURRY_LOOP_VOLUME = 1
local SCURRY_LOOP_SPEED = 1.3
local LOOP_FADE = 0.12
local LOOP_STOP_FADE = 0.3
local LOOP_RETRY = 1
local LOOP_MIX_SPEED = 8
local AUDIO_SPEED_SMOOTH = 12
local VOLUME_EPSILON = 0.02
local KNOCK_VOLUME = 1.1
local KNOCK_SPEED_MIN = 1.15
local KNOCK_SPEED_MAX = 1.4
local KNOCK_COOLDOWN = 0.3
local KNOCK_TURN = math.rad(30)
local KNOCK_SHAKE = 0.45 -- degrees at full strength
local KNOCK_SHAKE_SECONDS = 0.22
local TURN_KNOCK = 0.55
local BUMP_KNOCK = 1
local REVERSE_KNOCK = 0.4
local BUMP_SPEED = 1.5 -- studs/s: arriving at a stop faster than this bumps it
local FAST_SPEED = 1.5
local REVERSE_WINDOW = 0.35 -- seconds after moving fast in which a reversal knocks
local PLANT_SHAKE_CRAWL = 0.14 -- degrees per hand plant at full crawl speed
local PLANT_SHAKE_SCURRY = 0.24
local PLANT_SHAKE_SECONDS = 0.2
local PLANT_MIN_SPEED = 0.3

-- Vignette
local VIGNETTE_OPACITY = 0.8 -- edge opacity inside a duct
local VIGNETTE_SCURRY_OPACITY = 0.1 -- added at a full scurry (tunnel vision)
local VIGNETTE_DEPTH = 0.3 -- edge band as a share of the screen
local VIGNETTE_SCURRY_DEPTH = 0.06
local VIGNETTE_SIDE_SHARE = 0.55 -- side bands are a share of the width, so they read as thick as top and bottom
local VIGNETTE_FADE_IN = 5
local VIGNETTE_FADE_OUT = 7
local VIGNETTE_DISPLAY_ORDER = -11 -- under PanicVFX's vignette (-10) and the HUD

local PHYSICS = Enum.HumanoidStateType.Physics
local GETTING_UP = Enum.HumanoidStateType.GettingUp
local RUNNING = Enum.HumanoidStateType.Running

-- Every state the Humanoid could leave Physics for while the rail carries it.
local SUSPENDED_STATES: { Enum.HumanoidStateType } = {
	Enum.HumanoidStateType.Running,
	Enum.HumanoidStateType.RunningNoPhysics,
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.StrafingNoPhysics,
	Enum.HumanoidStateType.Jumping,
	Enum.HumanoidStateType.Freefall,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.Landed,
	Enum.HumanoidStateType.GettingUp,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.PlatformStanding,
}

local VENT_STATES: { [string]: boolean } = { VentCrawling = true, VentScurrying = true }

-- Overrides the server can hold while keeping the character in the duct (Vent collision stays on).
local DUCT_OVERRIDES: { [string]: boolean } = {
	DownedCrawling = true,
	Grabbed = true,
	Trapped = true,
	Hiding = true,
	Scripted = true,
	Parachuting = true,
}

local CRAWL_SPEEDS: { [string]: number } = {
	VentCrawling = GameConfig.VentCrawlSpeed,
	VentScurrying = GameConfig.VentScurrySpeed,
	DownedCrawling = GameConfig.DownedMoveSpeed,
}

local PASSABLE_STATES: { Enums.GrateState } = { "Open", "Kicked" }
local HEADINGS: { number } = { 1, -1 }
local PLANT_MARKS: { number } = { 0, 0.5 } -- PlayerR15's crawl: the left hand plants at 0, the right at 0.5

type Session = {
	trove: Trove.Trove,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	align: AlignPosition,
	orient: AlignOrientation,
	savedStates: { [Enum.HumanoidStateType]: boolean },
	rail: Rail?,
	graphRetryAt: number,
	cursor: Cursor?,
	heading: number,
	speed: number,
	railSpeed: number, -- smoothed studs/s actually travelled (audio, sway)
	facing: Vector3,
	facingYaw: number,
	holdPosition: Vector3?,
	holdYaw: number,
	holdUntil: number,
	paused: boolean,
	lastRoot: Vector3,
	leashSince: number?,
	pushingStop: boolean,
	lastKnockAt: number,
	lastFastAt: number,
	lastPhase: number?,
	scurryMix: number,
	crawlVoice: SoundSynthesizer.Voice?,
	scurryVoice: SoundSynthesizer.Voice?,
	crawlVolume: number,
	scurryVolume: number,
	loopRetryAt: number,
}

type GraphEntry = { source: Instance, graph: VentGraph.Graph }
type StopEntry = { model: Instance?, value: number, settled: boolean }

local VentController = {}

VentController.Name = "VentController"
VentController.MinTravelDot = MIN_TRAVEL_DOT
VentController.FullTravelDot = FULL_TRAVEL_DOT
VentController.RoundRadius = ROUND_RADIUS
VentController.Lookahead = LOOKAHEAD
VentController.BallRadius = BALL_RADIUS
VentController.PanelMargin = PANEL_MARGIN
VentController.JumpDistance = JUMP_DISTANCE
VentController.OnRail = ON_RAIL
VentController.MaxTurnRate = MAX_TURN_RATE
VentController.AccelTime = ACCEL_TIME
VentController.DecelTime = DECEL_TIME

local serviceTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local localRandom = Random.new()
local session: Session? = nil

local graphs: { [string]: GraphEntry } = {}
local graphMisses: { [string]: number } = {} -- levelId -> os.clock() before which a failed build is not retried
local grateModels: { [string]: Instance } = {}
local grateWatchers: { [Instance]: RBXScriptConnection } = {}
local grateChangedAt: { [string]: number } = {}
local stops: { [string]: StopEntry } = {}

local vignetteGui: ScreenGui? = nil
local vignetteEdges: { Frame } = {}
local vignetteLevel = 0
local vignetteDepth = VIGNETTE_DEPTH
local appliedOpacity = -1
local appliedDepth = -1

--------------------------------------------------------------------------------
-- Pure rail maths (specs: tests/Specs/VentController.spec.luau)
--------------------------------------------------------------------------------

local function flatten(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function flatUnit(v: Vector3): Vector3
	local flat = flatten(v)
	local magnitude = flat.Magnitude
	return if magnitude > 1e-6 then flat / magnitude else Vector3.zero
end

-- World ends of the cursor's duct: node a and node b, or node a and its grate's mouth (a stub).
function VentController.span(graph: VentGraph.Graph, cursor: Cursor): (Vector3?, Vector3?)
	local from = graph.nodes[cursor.a]
	if not from then
		return nil, nil
	end
	local b = cursor.b
	if b == nil then
		local grateId = graph.grateAtNode[cursor.a]
		local grate = if grateId then graph.grates[grateId] else nil
		if not grate then
			return nil, nil
		end
		return from.position, grate.mouth
	end
	local to = graph.nodes[b]
	if not to then
		return nil, nil
	end
	return from.position, to.position
end

-- Where the cursor puts the root (on the duct centreline).
function VentController.position(graph: VentGraph.Graph, cursor: Cursor): Vector3?
	local from, to = VentController.span(graph, cursor)
	if not from or not to then
		return nil
	end
	return from:Lerp(to, math.clamp(cursor.t, 0, 1))
end

-- A cursor at a VentGraph rail point. t is recomputed from the point's position along its own duct, so it means the
-- same here whatever units the graph uses.
function VentController.fromRailPoint(graph: VentGraph.Graph, point: VentGraph.RailPoint): Cursor
	local cursor: Cursor = { a = point.a, b = point.b, t = 0 }
	local from, to = VentController.span(graph, cursor)
	if from and to then
		local offset = to - from
		local lengthSquared = offset:Dot(offset)
		if lengthSquared > 1e-9 then
			cursor.t = math.clamp((point.position - from):Dot(offset) / lengthSquared, 0, 1)
		end
	end
	return cursor
end

-- True for the grate states a crawler can pass (Open, Kicked).
function VentController.isPassable(state: unknown): boolean
	return type(state) == "string" and table.find(PASSABLE_STATES, state :: any) ~= nil
end

-- Every way out of `nodeId`: one per linked node, plus its grate's mouth stub (blocked while the grate is shut).
function VentController.ways(rail: Rail, nodeId: string): { Way }
	local graph = rail.graph
	local out: { Way } = {}
	local node = graph.nodes[nodeId]
	if not node then
		return out
	end
	for _, other in node.links do
		local target = graph.nodes[other]
		if target then
			local offset = target.position - node.position
			if offset.Magnitude > 1e-6 then
				table.insert(out, { a = nodeId, b = other, direction = offset.Unit, blocked = false })
			end
		end
	end
	local grateId = graph.grateAtNode[nodeId]
	local grate = if grateId then graph.grates[grateId] else nil
	if grateId and grate then
		local offset = grate.mouth - node.position
		if offset.Magnitude > 1e-6 then
			table.insert(out, { a = nodeId, b = nil, direction = offset.Unit, blocked = not rail.passable(grateId) })
		end
	end
	return out
end

-- The ways out of `nodeId` (an end of the cursor's duct) other than back along that duct.
local function onward(rail: Rail, nodeId: string, cursor: Cursor): { Way }
	local fromA = nodeId == cursor.a
	local back: string? = if fromA then cursor.b else cursor.a
	local backIsStub = fromA and cursor.b == nil
	local out: { Way } = {}
	for _, way in VentController.ways(rail, nodeId) do
		local isBack = if backIsStub then way.b == nil else way.b == back
		if not isBack then
			table.insert(out, way)
		end
	end
	return out
end

local function openWays(ways: { Way }): { Way }
	local out: { Way } = {}
	for _, way in ways do
		if not way.blocked then
			table.insert(out, way)
		end
	end
	return out
end

-- The node at the `heading` end of the cursor's duct (nil past a mouth stub) and the distance to it.
local function frontOf(graph: VentGraph.Graph, cursor: Cursor, heading: number): (string?, number)
	local from, to = VentController.span(graph, cursor)
	local length = if from and to then (to - from).Magnitude else 0
	if heading > 0 then
		return cursor.b, (1 - cursor.t) * length
	end
	return cursor.a, cursor.t * length
end

-- Unit rail direction for travel along `heading` (+1 toward b / the mouth, -1 toward a). Within ROUND_RADIUS of a
-- node with exactly one way on (a bend), the tangent blends halfway toward that way at the node, so the direction
-- of travel turns continuously round the corner.
function VentController.tangent(rail: Rail, cursor: Cursor, heading: number): Vector3
	local from, to = VentController.span(rail.graph, cursor)
	if not from or not to then
		return Vector3.zero
	end
	local offset = to - from
	local length = offset.Magnitude
	if length < 1e-6 then
		return Vector3.zero
	end
	local sign = if heading < 0 then -1 else 1
	local base = offset.Unit * sign
	local ahead = (if sign > 0 then 1 - cursor.t else cursor.t) * length
	local behind = length - ahead
	local front: string? = if sign > 0 then cursor.b else cursor.a
	local rear: string? = if sign > 0 then cursor.a else cursor.b
	local blended = base
	if front ~= nil and ahead < ROUND_RADIUS then
		local next = openWays(onward(rail, front, cursor))
		if #next == 1 then
			blended += (next[1].direction - base) * (0.5 * (1 - ahead / ROUND_RADIUS))
		end
	end
	if rear ~= nil and behind < ROUND_RADIUS then
		local previous = openWays(onward(rail, rear, cursor))
		if #previous == 1 then
			blended += (-previous[1].direction - base) * (0.5 * (1 - behind / ROUND_RADIUS))
		end
	end
	if blended.Magnitude < 1e-4 then
		return base
	end
	return blended.Unit
end

-- Input -> travel along the rail: (heading, strength). `input` is the camera-relative move vector (Humanoid
-- MoveDirection; its length is the stick's deflection). The heading is the way along the duct whose tangent best
-- matches the input; a node within LOOKAHEAD also offers the branches the input points down. Below MIN_TRAVEL_DOT
-- the input points into a wall: (0, 0). Strength ramps from 0 at MIN_TRAVEL_DOT to the input's length at
-- FULL_TRAVEL_DOT. `prefer` (the heading already moving) wins near-ties.
function VentController.travel(rail: Rail, cursor: Cursor, input: Vector3, prefer: number?): (number, number)
	local flatInput = flatten(input)
	local magnitude = flatInput.Magnitude
	if magnitude < INPUT_DEADZONE then
		return 0, 0
	end
	local unit = flatInput / magnitude
	local bestHeading, bestScore, bestRank = 0, -math.huge, -math.huge
	for _, heading in HEADINGS do
		local score = unit:Dot(flatUnit(VentController.tangent(rail, cursor, heading)))
		local front, distance = frontOf(rail.graph, cursor, heading)
		if front ~= nil and distance <= LOOKAHEAD then
			for _, way in openWays(onward(rail, front, cursor)) do
				score = math.max(score, unit:Dot(flatUnit(way.direction)))
			end
		end
		local rank = score + (if heading == prefer then PREFER_BONUS else 0)
		if rank > bestRank then
			bestHeading, bestScore, bestRank = heading, score, rank
		end
	end
	if bestScore < MIN_TRAVEL_DOT then
		return 0, 0
	end
	return bestHeading, math.min(magnitude, 1) * MathUtil.smoothstep(MIN_TRAVEL_DOT, FULL_TRAVEL_DOT, bestScore)
end

-- The way to take at a node. `ways` excludes the duct we arrived on; blocked ways (a shut grate's stub) are never
-- taken. One way on (a bend, a straight joint, an open grate's stub) is simply followed when we arrived moving
-- (`arrival` given); otherwise the way most aligned with the input wins if its dot reaches MIN_TRAVEL_DOT; nil = stop.
function VentController.chooseBranch(ways: { Way }, input: Vector3, arrival: Vector3?): Way?
	local open = openWays(ways)
	if #open == 0 then
		return nil
	end
	if #open == 1 and arrival ~= nil then
		return open[1]
	end
	local flatInput = flatten(input)
	if flatInput.Magnitude < INPUT_DEADZONE then
		return nil
	end
	local unit = flatInput.Unit
	local best: Way? = nil
	local bestDot = MIN_TRAVEL_DOT
	for _, way in open do
		local dot = unit:Dot(flatUnit(way.direction))
		if dot >= bestDot then
			best = way
			bestDot = dot
		end
	end
	return best
end

local function stopReason(ways: { Way }): StopReason
	local open = 0
	for _, way in ways do
		if way.blocked then
			return "Blocked"
		end
		open += 1
	end
	return if open == 0 then "DeadEnd" else "Junction"
end

-- Moves the cursor `distance` studs along `heading`, across nodes (chooseBranch with `input`), stopping at dead
-- ends, at junctions the input does not choose, at the mouth end of a stub, and short of a shut grate (its
-- stopShort before the grate's node, or at the start of its stub).
function VentController.advance(rail: Rail, cursor: Cursor, heading: number, distance: number, input: Vector3): Step
	local graph = rail.graph
	local current: Cursor = { a = cursor.a, b = cursor.b, t = math.clamp(cursor.t, 0, 1) }
	local sign = if heading < 0 then -1 else 1
	local remaining = if distance > 0 and distance == distance then distance else 0
	local travelled = 0
	local turned = 0
	local stopped: StopReason? = nil
	for _ = 1, MAX_HOPS do
		local from, to = VentController.span(graph, current)
		if not from or not to then
			stopped = "DeadEnd"
			break
		end
		local length = math.max((to - from).Magnitude, 1e-6)
		local ahead = (if sign > 0 then 1 - current.t else current.t) * length
		local front: string? = if sign > 0 then current.b else current.a
		local room = ahead
		local shut = false
		if current.b == nil then
			local grateId = graph.grateAtNode[current.a]
			if sign > 0 and grateId ~= nil and not rail.passable(grateId) then
				room, shut = 0, true -- never further out along a shut grate's stub
			end
		elseif front ~= nil then
			local grateId = graph.grateAtNode[front]
			if grateId ~= nil and not rail.passable(grateId) then
				local short = rail.stopShort(grateId)
				if short > 0 then
					room, shut = math.max(0, ahead - short), true
				end
			end
		end
		if remaining <= room then
			current.t = math.clamp(current.t + sign * remaining / length, 0, 1)
			travelled += remaining
			remaining = 0
			break
		end
		current.t = math.clamp(current.t + sign * room / length, 0, 1)
		travelled += room
		remaining -= room
		if shut then
			stopped = "Blocked"
			break
		end
		if front == nil then
			stopped = "Mouth"
			break
		end
		local arrival = (to - from).Unit * sign
		local ways = onward(rail, front, current)
		local choice = VentController.chooseBranch(ways, input, arrival)
		if choice == nil then
			stopped = stopReason(ways)
			break
		end
		local turn = math.acos(math.clamp(flatUnit(arrival):Dot(flatUnit(choice.direction)), -1, 1))
		turned = math.max(turned, turn)
		current = { a = front, b = choice.b, t = 0 }
		sign = 1
	end
	return { cursor = current, heading = sign, travelled = travelled, stopped = stopped, turned = turned }
end

-- How deep the cursor sits inside a shut grate's keep-out (0 when clear) and the heading that leads out of it.
function VentController.encroachment(rail: Rail, cursor: Cursor): (number, number)
	local graph = rail.graph
	local from, to = VentController.span(graph, cursor)
	if not from or not to then
		return 0, 0
	end
	local length = (to - from).Magnitude
	if cursor.b == nil then
		local grateId = graph.grateAtNode[cursor.a]
		if grateId ~= nil and not rail.passable(grateId) then
			return cursor.t * length + rail.stopShort(grateId), -1
		end
		return 0, 0
	end
	local worst, away = 0, 0
	local ends: { { node: string, distance: number, away: number } } = {
		{ node = cursor.a, distance = cursor.t * length, away = 1 },
		{ node = cursor.b :: string, distance = (1 - cursor.t) * length, away = -1 },
	}
	for _, entry in ends do
		local grateId = graph.grateAtNode[entry.node]
		if grateId ~= nil and not rail.passable(grateId) then
			local depth = rail.stopShort(grateId) - entry.distance
			if depth > worst then
				worst, away = depth, entry.away
			end
		end
	end
	return worst, away
end

-- Studs before a shut grate's node the ball centre must stop. `contact` is where a ball-sized probe moving out
-- along the grate's LookVector first touched its panel (ball centre, studs past the node toward the room); without
-- a measurement the panel is assumed at the wall's room face.
function VentController.panelStop(contact: number?): number
	local at = if contact ~= nil and MathUtil.isFinite(contact) then contact else PANEL_FALLBACK - BALL_RADIUS
	return math.clamp(PANEL_MARGIN - at, 0, BALL_RADIUS + PANEL_MARGIN + WorldConfig.VentBore)
end

-- The direction the body lies along: the rail tangent (either way) nearest the camera `look`, held toward
-- `current` by FACING_HYSTERESIS so looking at a side wall never flips it.
function VentController.chooseFacing(rail: Rail, cursor: Cursor, look: Vector3, current: Vector3?): Vector3
	local forward = flatUnit(VentController.tangent(rail, cursor, 1))
	local backward = flatUnit(VentController.tangent(rail, cursor, -1))
	if forward.Magnitude < 0.5 or backward.Magnitude < 0.5 then
		return current or flatUnit(look)
	end
	local flatLook = flatUnit(look)
	local held = if current then flatUnit(current) else Vector3.zero
	local forwardScore = flatLook:Dot(forward) + FACING_HYSTERESIS * held:Dot(forward)
	local backwardScore = flatLook:Dot(backward) + FACING_HYSTERESIS * held:Dot(backward)
	return if backwardScore > forwardScore then backward else forward
end

-- Eases a yaw toward `target`: exponential at FACING_SPEED, never faster than MAX_TURN_RATE, the short way round.
function VentController.smoothYaw(current: number, target: number, dt: number): number
	local delta = MathUtil.angleDelta(current, target)
	local limit = MAX_TURN_RATE * math.max(dt, 0)
	local step = math.clamp(delta * MathUtil.damp(FACING_SPEED, math.max(dt, 0)), -limit, limit)
	return MathUtil.wrapAngle(current + step)
end

-- One frame of rail speed: (speed, heading, reversed). Accelerates to `want` (studs/s) along `wantHeading` over
-- ACCEL_TIME at `top`, slows over DECEL_TIME, and brakes to a stop before reversing (`reversed` on the frame it
-- turns round). wantHeading 0 coasts to a stop along the current heading.
function VentController.stepSpeed(
	speed: number,
	heading: number,
	wantHeading: number,
	want: number,
	top: number,
	dt: number
): (number, number, boolean)
	local accel = math.max(top, 1) / ACCEL_TIME
	local decel = math.max(top, speed, 1) / DECEL_TIME
	if wantHeading == 0 or want <= 0 then
		return MathUtil.approach(speed, 0, decel * dt), heading, false
	end
	if speed > SPEED_EPSILON and wantHeading ~= heading then
		local braked = MathUtil.approach(speed, 0, decel * dt)
		if braked > SPEED_EPSILON then
			return braked, heading, false
		end
		return 0, wantHeading, true
	end
	local target = math.min(want, math.max(top, 0))
	local rate = if speed < target then accel else decel
	return MathUtil.approach(speed, target, rate * dt), wantHeading, false
end

-- What the session should do this frame.
function VentController.membership(input: MembershipInput): Membership
	if not input.alive then
		return if input.engaged then "Release" else "Idle"
	end
	local crawling = VENT_STATES[input.moveState] == true
	if not input.engaged then
		return if crawling then "Engage" else "Idle"
	end
	local held = input.locked or input.collider == "Locked"
	if crawling then
		return if held then "Hold" else "Drive"
	end
	if DUCT_OVERRIDES[input.moveState] == true and input.collider ~= "Normal" then
		return if held then "Hold" else "Drive"
	end
	return "Release"
end

-- The collision mode CollisionService applied, read back from the parts: the VentCollider ball is in its group only
-- in Vent mode; every other part is NoCollide in Vent and Locked mode and Players in Normal mode.
function VentController.colliderMode(ballGroup: string?, rootGroup: string?): ColliderMode
	if ballGroup == CollisionGroups.VentCollider then
		return "Vent"
	end
	if rootGroup == CollisionGroups.NoCollide then
		return if ballGroup == nil then "Vent" else "Locked"
	end
	return "Normal"
end

-- A root that moved `jump` studs since the last frame and sits `gap` from the cursor: the server's doing when both
-- reach JUMP_DISTANCE; onto the rail (`railDistance` within ON_RAIL) re-snap, anywhere else hold.
function VentController.serverMove(jump: number, gap: number, railDistance: number?): ServerMove
	if jump < JUMP_DISTANCE or gap < JUMP_DISTANCE then
		return "None"
	end
	if railDistance ~= nil and railDistance <= ON_RAIL then
		return "Resnap"
	end
	return "Hold"
end

-- Rail speed for a MoveState (MovementController's WalkSpeed table for the states a duct holds; 0 for holds).
function VentController.crawlSpeed(state: string): number
	return CRAWL_SPEEDS[state] or 0
end

-- Loop volume for a rail `speed`: silent at rest, rising with speed; the scurry voice is the louder one.
function VentController.crawlVolume(speed: number, scurrying: boolean): number
	local nominal = if scurrying then GameConfig.VentScurrySpeed else GameConfig.VentCrawlSpeed
	local level = if scurrying then SCURRY_LOOP_VOLUME else CRAWL_LOOP_VOLUME
	return level * math.clamp(speed / nominal, 0, 1.15)
end

-- Vignette (edge opacity, band depth) for how far into the duct we are (`level` 0..1) and the scurry mix.
function VentController.vignette(level: number, scurryMix: number): (number, number)
	local inside = MathUtil.clamp01(level)
	local scurry = MathUtil.clamp01(scurryMix)
	return inside * (VIGNETTE_OPACITY + VIGNETTE_SCURRY_OPACITY * scurry),
		VIGNETTE_DEPTH + VIGNETTE_SCURRY_DEPTH * scurry
end

-- Whether the crawl's gait phase passed a hand plant between two readings (forward only; a jump of half a cycle
-- or more is a reset, not a step).
function VentController.plantCrossed(previous: number, current: number): boolean
	local delta = (current - previous) % 1
	if delta <= 0 or delta >= 0.5 then
		return false
	end
	for _, mark in PLANT_MARKS do
		if ProceduralAnimator.crossed(previous, previous + delta, mark) then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Graphs and grates
--------------------------------------------------------------------------------

local function graphFor(levelId: string, now: number): VentGraph.Graph?
	local entry = graphs[levelId]
	if entry and entry.source.Parent ~= nil then
		return entry.graph
	end
	local missUntil = graphMisses[levelId]
	if missUntil and now < missUntil then
		return nil
	end
	local levelRoot = Instances.layoutRoot(levelId)
	local graph = if levelRoot then VentGraph.build(levelRoot, levelId) else nil
	if levelRoot and graph then
		graphs[levelId] = { source = levelRoot, graph = graph }
		graphMisses[levelId] = nil
		return graph
	end
	graphMisses[levelId] = now + GRAPH_RETRY * 4
	return nil
end

-- The level whose rail passes closest to `position`: the current level and the player's own first, every level
-- with vent nodes when neither has a duct within ENGAGE_RADIUS.
local function resolveGraph(player: Player, position: Vector3, now: number): (VentGraph.Graph?, VentGraph.RailPoint?)
	local tried: { [string]: boolean } = {}
	local bestGraph: VentGraph.Graph? = nil
	local bestPoint: VentGraph.RailPoint? = nil
	local function consider(value: unknown): boolean
		if type(value) ~= "string" or value == "" or tried[value] then
			return false
		end
		tried[value] = true
		local graph = graphFor(value, now)
		local point = if graph then VentGraph.nearest(graph, position) else nil
		if graph and point and (bestPoint == nil or point.distance < bestPoint.distance) then
			bestGraph, bestPoint = graph, point
		end
		return bestPoint ~= nil and bestPoint.distance <= ENGAGE_RADIUS
	end
	if consider(ReplicatedStorage:GetAttribute(M.CurrentLevel)) or consider(player:GetAttribute(P.LevelId)) then
		return bestGraph, bestPoint
	end
	for _, node in CollectionService:GetTagged(Tags.VentNode) do
		if consider(node:GetAttribute(W.LevelId)) then
			break
		end
	end
	return bestGraph, bestPoint
end

local function grateOpen(grateId: string): boolean
	local model = grateModels[grateId]
	if not model or model.Parent == nil then
		return false
	end
	return VentController.isPassable(model:GetAttribute(W.GrateState))
end

-- Ball centre at first contact with the grate's panel, studs past `origin` along the wall's LookVector.
local function measureContact(model: Instance, wall: CFrame, origin: Vector3): number?
	local look = wall.LookVector
	local start = origin - look * PROBE_BACK
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { model }
	params.CollisionGroup = CollisionGroups.Default
	params.RespectCanCollide = true
	local ok, hit = pcall(function(): RaycastResult?
		return Workspace:Spherecast(start, BALL_RADIUS, look * (PROBE_BACK + PROBE_REACH), params)
	end)
	if not ok or hit == nil then
		return nil
	end
	return (start + look * hit.Distance - origin):Dot(look)
end

local function stopShortFor(graph: VentGraph.Graph, grateId: string): number
	local model = grateModels[grateId]
	local cached = stops[grateId]
	if cached and cached.model == model and cached.settled then
		return cached.value
	end
	local grate = graph.grates[grateId]
	local node = if grate then graph.nodes[grate.nodeId] else nil
	local changedAt = grateChangedAt[grateId]
	local settled = false
	local contact: number? = nil
	if model then
		settled = changedAt == nil or os.clock() - changedAt >= PANEL_SETTLE
		if settled and grate and node then
			contact = measureContact(model, grate.wall, node.position)
		end
	end
	local value = VentController.panelStop(contact)
	stops[grateId] = { model = model, value = value, settled = settled }
	return value
end

local function railFor(graph: VentGraph.Graph): Rail
	return {
		graph = graph,
		passable = grateOpen,
		stopShort = function(grateId: string): number
			return stopShortFor(graph, grateId)
		end,
	}
end

local function removeGrate(instance: Instance)
	local watcher = grateWatchers[instance]
	if watcher then
		grateWatchers[instance] = nil
		watcher:Disconnect()
	end
	for grateId, model in grateModels do
		if model == instance then
			grateModels[grateId] = nil
			stops[grateId] = nil
		end
	end
end

local function addGrate(instance: Instance)
	local grateId = instance:GetAttribute(W.GrateId)
	if type(grateId) ~= "string" or grateId == "" or grateWatchers[instance] then
		return
	end
	grateModels[grateId] = instance
	stops[grateId] = nil
	grateChangedAt[grateId] = os.clock()
	grateWatchers[instance] = instance:GetAttributeChangedSignal(W.GrateState):Connect(function()
		grateChangedAt[grateId] = os.clock()
		stops[grateId] = nil
	end)
end

--------------------------------------------------------------------------------
-- Presentation
--------------------------------------------------------------------------------

local function newEdge(parent: Instance, name: string, rotation: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.Active = false
	frame.Selectable = false
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.3),
		NumberSequenceKeypoint.new(0.7, 0.82),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	frame.Parent = parent
	return frame
end

local function ensureVignette(player: Player): ScreenGui?
	local existing = vignetteGui
	if existing and existing.Parent ~= nil then
		return existing
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local screen = Instance.new("ScreenGui")
	screen.Name = VIGNETTE_NAME
	screen.ResetOnSpawn = false
	screen.ScreenInsets = Enum.ScreenInsets.None
	screen.DisplayOrder = VIGNETTE_DISPLAY_ORDER
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false
	local top = newEdge(screen, "Top", 90)
	top.Position = UDim2.fromScale(0, 0)
	local bottom = newEdge(screen, "Bottom", -90)
	bottom.AnchorPoint = Vector2.new(0, 1)
	bottom.Position = UDim2.fromScale(0, 1)
	local left = newEdge(screen, "Left", 0)
	left.Position = UDim2.fromScale(0, 0)
	local right = newEdge(screen, "Right", 180)
	right.AnchorPoint = Vector2.new(1, 0)
	right.Position = UDim2.fromScale(1, 0)
	vignetteEdges = { top, bottom, left, right }
	appliedOpacity, appliedDepth = -1, -1
	screen.Parent = playerGui
	vignetteGui = screen
	serviceTrove:Add(screen)
	return screen
end

local function applyVignette(player: Player, opacity: number, depth: number)
	if opacity <= 0.002 then
		local screen = vignetteGui
		if screen and screen.Enabled then
			screen.Enabled = false
		end
		return
	end
	local screen = ensureVignette(player)
	if not screen then
		return
	end
	if not screen.Enabled then
		screen.Enabled = true
	end
	if math.abs(opacity - appliedOpacity) > 0.004 then
		appliedOpacity = opacity
		for _, edge in vignetteEdges do
			edge.BackgroundTransparency = 1 - opacity
		end
	end
	if math.abs(depth - appliedDepth) > 0.002 then
		appliedDepth = depth
		vignetteEdges[1].Size = UDim2.fromScale(1, depth)
		vignetteEdges[2].Size = UDim2.fromScale(1, depth)
		vignetteEdges[3].Size = UDim2.fromScale(depth * VIGNETTE_SIDE_SHARE, 1)
		vignetteEdges[4].Size = UDim2.fromScale(depth * VIGNETTE_SIDE_SHARE, 1)
	end
end

local function stopVoice(voice: SoundSynthesizer.Voice?)
	if voice then
		voice:Stop(LOOP_STOP_FADE)
	end
end

-- A sheet-metal knock (a pitched VentCrawl hit) with a matching jolt, at most every KNOCK_COOLDOWN.
local function knock(current: Session, now: number, strength: number)
	if now - current.lastKnockAt < KNOCK_COOLDOWN then
		return
	end
	current.lastKnockAt = now
	local level = MathUtil.clamp01(strength)
	AudioController.PlayLocal(CRAWL_PRESET, {
		volume = KNOCK_VOLUME * (0.6 + 0.4 * level),
		speed = localRandom:NextNumber(KNOCK_SPEED_MIN, KNOCK_SPEED_MAX),
	})
	FirstPersonController.Shake(KNOCK_SHAKE * level, KNOCK_SHAKE_SECONDS)
end

-- Keeps the crawl and scurry loops playing at the volumes the rail speed asks for.
local function driveLoops(current: Session, now: number, scurrying: boolean, dt: number)
	current.scurryMix = MathUtil.dampNumber(current.scurryMix, if scurrying then 1 else 0, LOOP_MIX_SPEED, dt)
	local speed = current.railSpeed
	local crawlTarget = VentController.crawlVolume(speed, false) * (1 - current.scurryMix)
	local scurryTarget = VentController.crawlVolume(speed, true) * current.scurryMix
	local crawlVoice = current.crawlVoice
	local scurryVoice = current.scurryVoice
	local missing = (crawlVoice == nil or not crawlVoice:IsPlaying())
		or (scurryVoice == nil or not scurryVoice:IsPlaying())
	if missing and now >= current.loopRetryAt then
		current.loopRetryAt = now + LOOP_RETRY
		if crawlVoice == nil or not crawlVoice:IsPlaying() then
			crawlVoice = AudioController.PlayLocal(CRAWL_PRESET, { looped = true, volume = crawlTarget })
			current.crawlVoice = crawlVoice
			current.crawlVolume = crawlTarget
		end
		if scurryVoice == nil or not scurryVoice:IsPlaying() then
			scurryVoice = AudioController.PlayLocal(
				CRAWL_PRESET,
				{ looped = true, volume = scurryTarget, speed = SCURRY_LOOP_SPEED }
			)
			current.scurryVoice = scurryVoice
			current.scurryVolume = scurryTarget
		end
	end
	if crawlVoice and math.abs(crawlTarget - current.crawlVolume) > VOLUME_EPSILON then
		current.crawlVolume = crawlTarget
		crawlVoice:SetVolume(crawlTarget, LOOP_FADE)
	end
	if scurryVoice and math.abs(scurryTarget - current.scurryVolume) > VOLUME_EPSILON then
		current.scurryVolume = scurryTarget
		scurryVoice:SetVolume(scurryTarget, LOOP_FADE)
	end
end

-- A small jolt on every hand plant of the crawl, in step with the local Animator's gait.
local function plantSway(current: Session, player: Player, scurrying: boolean)
	local animator = CharacterAnimationController.GetAnimator(player)
	if not animator then
		current.lastPhase = nil
		return
	end
	local phase = animator:GetPhase()
	local previous = current.lastPhase
	current.lastPhase = phase
	if previous == nil or current.railSpeed < PLANT_MIN_SPEED or VENT_STATES[animator:GetState()] ~= true then
		return
	end
	if VentController.plantCrossed(previous, phase) then
		local nominal = if scurrying then GameConfig.VentScurrySpeed else GameConfig.VentCrawlSpeed
		local amplitude = (if scurrying then PLANT_SHAKE_SCURRY else PLANT_SHAKE_CRAWL)
			* math.clamp(current.railSpeed / nominal, 0, 1)
		FirstPersonController.Shake(amplitude, PLANT_SHAKE_SECONDS)
	end
end

local function present(current: Session?, player: Player, dt: number, now: number)
	local target = if current then 1 else 0
	vignetteLevel = MathUtil.dampNumber(
		vignetteLevel,
		target,
		if target > vignetteLevel then VIGNETTE_FADE_IN else VIGNETTE_FADE_OUT,
		dt
	)
	if target == 0 and vignetteLevel < 0.005 then
		vignetteLevel = 0
	end
	local scurryMix = if current then current.scurryMix else 0
	local opacity, depth = VentController.vignette(vignetteLevel, scurryMix)
	vignetteDepth = MathUtil.dampNumber(vignetteDepth, depth, VIGNETTE_FADE_IN, dt)
	applyVignette(player, opacity, vignetteDepth)
	if not current then
		return
	end
	local scurrying = FirstPersonController.GetPredictedMoveState() == "VentScurrying"
	driveLoops(current, now, scurrying, dt)
	plantSway(current, player, scurrying)
end

--------------------------------------------------------------------------------
-- Session
--------------------------------------------------------------------------------

local function yawOf(direction: Vector3): number
	local yaw = MathUtil.yawPitchFromVector(direction)
	return yaw
end

local function setConstraints(current: Session, on: boolean)
	if current.align.Enabled ~= on then
		current.align.Enabled = on
	end
	if current.orient.Enabled ~= on then
		current.orient.Enabled = on
	end
end

-- Forgets the motion state after the body was put somewhere new (a snap, a server move).
local function resetMotion(current: Session)
	current.speed = 0
	current.leashSince = nil
	current.pushingStop = false
	local facing = flatUnit(current.root.CFrame.LookVector)
	if facing.Magnitude > 0.5 then
		current.facing = facing
		current.facingYaw = yawOf(facing)
	end
end

local function engage(character: Model, humanoid: Humanoid, root: BasePart, now: number): Session
	local trove = Trove.new()
	local yaw = yawOf(root.CFrame.LookVector)

	local attachment = Instance.new("Attachment")
	attachment.Name = CONSTRAINT_NAME
	attachment.Parent = root
	trove:Add(attachment)

	local align = Instance.new("AlignPosition")
	align.Name = CONSTRAINT_NAME
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.Responsiveness = ALIGN_RESPONSIVENESS
	align.MaxForce = ALIGN_MAX_FORCE
	align.MaxVelocity = ALIGN_MAX_VELOCITY
	align.ApplyAtCenterOfMass = true
	align.Position = root.Position
	align.Parent = root
	trove:Add(align)

	local orient = Instance.new("AlignOrientation")
	orient.Name = CONSTRAINT_NAME
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.AlignType = Enum.AlignType.AllAxes
	orient.Attachment0 = attachment
	orient.RigidityEnabled = false
	orient.Responsiveness = ORIENT_RESPONSIVENESS
	orient.MaxTorque = ORIENT_MAX_TORQUE
	orient.MaxAngularVelocity = ORIENT_MAX_ANGULAR
	orient.CFrame = CFrame.fromOrientation(0, yaw, 0)
	orient.Parent = root
	trove:Add(orient)

	local saved: { [Enum.HumanoidStateType]: boolean } = {}
	for _, state in SUSPENDED_STATES do
		saved[state] = humanoid:GetStateEnabled(state)
		humanoid:SetStateEnabled(state, false)
	end
	humanoid:ChangeState(PHYSICS)

	FirstPersonController.SuspendBodyYaw(TOKEN, true)
	FirstPersonController.SetMoveModeHint("Vent")
	InputController.PushContext(VENT_CONTEXT, TOKEN)
	AudioController.SetEnvironmentOverride(VENT_ACOUSTICS)

	local current: Session = {
		trove = trove,
		character = character,
		humanoid = humanoid,
		root = root,
		align = align,
		orient = orient,
		savedStates = saved,
		rail = nil,
		graphRetryAt = now,
		cursor = nil,
		heading = 1,
		speed = 0,
		railSpeed = 0,
		facing = flatUnit(root.CFrame.LookVector),
		facingYaw = yaw,
		holdPosition = nil,
		holdYaw = yaw,
		holdUntil = now + ENTRY_WAIT,
		paused = false,
		lastRoot = root.Position,
		leashSince = nil,
		pushingStop = false,
		lastKnockAt = -math.huge,
		lastFastAt = -math.huge,
		lastPhase = nil,
		scurryMix = 0,
		crawlVoice = nil,
		scurryVoice = nil,
		crawlVolume = 0,
		scurryVolume = 0,
		loopRetryAt = now,
	}
	session = current
	return current
end

local function release()
	local current = session
	if not current then
		return
	end
	session = nil
	stopVoice(current.crawlVoice)
	stopVoice(current.scurryVoice)
	current.trove:Destroy()
	local humanoid = current.humanoid
	if humanoid.Parent ~= nil then
		for state, enabled in current.savedStates do
			humanoid:SetStateEnabled(state, enabled)
		end
		if humanoid.Health > 0 and humanoid:GetState() == PHYSICS then
			humanoid:ChangeState(if humanoid:GetStateEnabled(GETTING_UP) then GETTING_UP else RUNNING)
		end
	end
	FirstPersonController.SuspendBodyYaw(TOKEN, false)
	FirstPersonController.SetMoveModeHint(nil)
	InputController.PopContext(TOKEN)
	AudioController.SetEnvironmentOverride(nil)
end

-- Lets go of the body while the server holds it (a ControlLock, an anchored root).
local function pause(current: Session, now: number)
	setConstraints(current, false)
	current.paused = true
	current.speed = 0
	current.railSpeed = 0
	current.holdUntil = now + HOLD_TIMEOUT
end

-- Holds the body still where it is (waiting for the entry teleport, after an off-rail server move).
local function hold(current: Session, rootPosition: Vector3)
	if current.holdPosition == nil then
		current.holdPosition = rootPosition
		current.holdYaw = yawOf(current.root.CFrame.LookVector)
	end
	current.align.Position = current.holdPosition or rootPosition
	current.orient.CFrame = CFrame.fromOrientation(0, current.holdYaw, 0)
	current.speed = 0
	current.railSpeed = 0
end

-- Puts the cursor on the rail: where the root already is, or, once the wait is over, the nearest rail point.
local function acquire(current: Session, player: Player, rail: Rail, rootPosition: Vector3, now: number): Cursor?
	local point = VentGraph.nearest(rail.graph, rootPosition, ON_RAIL)
	if point == nil and now >= current.holdUntil then
		point = VentGraph.nearest(rail.graph, rootPosition, ENGAGE_RADIUS)
		if point == nil then
			local graph, best = resolveGraph(player, rootPosition, now)
			if graph and best then
				current.rail = railFor(graph)
				rail = current.rail :: Rail
				point = best
			end
		end
	end
	if point == nil then
		return nil
	end
	local cursor = VentController.fromRailPoint(rail.graph, point)
	current.cursor = cursor
	current.holdPosition = nil
	resetMotion(current)
	return cursor
end

-- The session's rail, resolved (at most every GRAPH_RETRY) while it has none.
local function railOf(current: Session, player: Player, rootPosition: Vector3, now: number): Rail?
	local rail = current.rail
	if rail then
		return rail
	end
	if now < current.graphRetryAt then
		return nil
	end
	current.graphRetryAt = now + GRAPH_RETRY
	local graph = resolveGraph(player, rootPosition, now)
	if not graph then
		log.warnThrottled("graph", 10, "no vent graph near %s; holding still", tostring(rootPosition))
		return nil
	end
	local fresh = railFor(graph)
	current.rail = fresh
	return fresh
end

-- The cursor once this frame's server moves are accounted for: a root the server put back on the rail re-snaps
-- the cursor there; one it moved off the rail drops the cursor (nil) and the body is held.
local function checkServerMove(
	current: Session,
	graph: VentGraph.Graph,
	rootPosition: Vector3,
	moved: number,
	now: number
): Cursor?
	local cursor = current.cursor
	if cursor == nil then
		return nil
	end
	local cursorPosition = VentController.position(graph, cursor)
	if cursorPosition == nil then
		current.cursor = nil
		return nil
	end
	local gap = (rootPosition - cursorPosition).Magnitude
	if moved < JUMP_DISTANCE or gap < JUMP_DISTANCE then
		return cursor
	end
	local point = VentGraph.nearest(graph, rootPosition, ON_RAIL)
	local verdict = VentController.serverMove(moved, gap, if point then point.distance else nil)
	if verdict == "Resnap" and point then
		local snapped = VentController.fromRailPoint(graph, point)
		current.cursor = snapped
		resetMotion(current)
		return snapped
	elseif verdict == "Hold" then
		current.cursor = nil
		current.holdPosition = nil
		current.holdUntil = now + HOLD_TIMEOUT
		return nil
	end
	return cursor
end

local function drive(current: Session, player: Player, dt: number, now: number)
	local root = current.root
	local humanoid = current.humanoid
	if current.paused then
		-- The server let go of us: start again from wherever it left the body.
		current.paused = false
		current.cursor = nil
		current.holdPosition = nil
		current.lastRoot = root.Position
	end
	setConstraints(current, true)
	if humanoid:GetState() ~= PHYSICS then
		humanoid:ChangeState(PHYSICS)
	end

	local rootPosition = root.Position
	local moved = (rootPosition - current.lastRoot).Magnitude
	current.lastRoot = rootPosition

	local foundRail = railOf(current, player, rootPosition, now)
	if foundRail == nil then
		hold(current, rootPosition)
		return
	end
	local foundCursor = checkServerMove(current, foundRail.graph, rootPosition, moved, now)
		or acquire(current, player, foundRail, rootPosition, now)
	local activeRail = current.rail
	if foundCursor == nil or activeRail == nil then
		hold(current, rootPosition)
		return
	end
	local rail: Rail = activeRail
	local cursor: Cursor = foundCursor
	local graph = rail.graph

	-- Travel
	local state = FirstPersonController.GetPredictedMoveState()
	local top = VentController.crawlSpeed(state)
	local input = humanoid.MoveDirection
	local travelled = 0
	local encroached, away = VentController.encroachment(rail, cursor)
	if encroached > 1e-3 then
		-- A grate shut on us: back out of its panel's way at a crawl.
		local retreat = math.min(encroached, math.max(top, GameConfig.VentCrawlSpeed) * dt)
		local step = VentController.advance(rail, cursor, away, retreat, Vector3.zero)
		cursor = step.cursor
		current.heading = step.heading
		current.speed = 0
		travelled = step.travelled
	else
		local moving = current.speed > SPEED_EPSILON
		local wantHeading, strength =
			VentController.travel(rail, cursor, input, if moving then current.heading else nil)
		local before = current.speed
		local speed, heading, reversed =
			VentController.stepSpeed(current.speed, current.heading, wantHeading, top * strength, top, dt)
		current.speed, current.heading = speed, heading
		if reversed and now - current.lastFastAt <= REVERSE_WINDOW then
			knock(current, now, REVERSE_KNOCK)
		end
		if speed > FAST_SPEED then
			current.lastFastAt = now
		end

		local cursorPosition = VentController.position(graph, cursor) or rootPosition
		if (rootPosition - cursorPosition).Magnitude > LEASH then
			-- The body is behind the cursor: wait for it, and if it stays caught start again from where it is.
			local since = current.leashSince or now
			current.leashSince = since
			if now - since >= STUCK_SECONDS then
				local point = VentGraph.nearest(graph, rootPosition, ENGAGE_RADIUS)
				if point then
					cursor = VentController.fromRailPoint(graph, point)
				end
				resetMotion(current)
			end
		else
			current.leashSince = nil
			local step = VentController.advance(rail, cursor, current.heading, current.speed * dt, input)
			cursor = step.cursor
			current.heading = step.heading
			travelled = step.travelled
			local stopped = step.stopped
			if stopped then
				local pushing = wantHeading ~= 0 and strength > 0
				if
					pushing
					and not current.pushingStop
					and before > BUMP_SPEED
					and (stopped == "DeadEnd" or stopped == "Blocked")
				then
					knock(current, now, BUMP_KNOCK)
				end
				current.pushingStop = pushing
				current.speed = 0
			else
				current.pushingStop = false
			end
			if step.turned >= KNOCK_TURN then
				knock(current, now, TURN_KNOCK)
			end
		end
	end
	current.cursor = cursor
	current.railSpeed =
		MathUtil.dampNumber(current.railSpeed, if dt > 0 then travelled / dt else 0, AUDIO_SPEED_SMOOTH, dt)

	-- Facing and the constraint targets
	local lookYaw = FirstPersonController.GetLook()
	current.facing = VentController.chooseFacing(rail, cursor, MathUtil.vectorFromYawPitch(lookYaw, 0), current.facing)
	current.facingYaw = VentController.smoothYaw(current.facingYaw, yawOf(current.facing), dt)
	local target = VentController.position(graph, cursor)
	if target then
		current.align.Position = target
	end
	current.orient.CFrame = CFrame.fromOrientation(0, current.facingYaw, 0)
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function frame(deltaTime: number)
	local player = localPlayer
	if not player then
		return
	end
	local dt = math.clamp(deltaTime, 0, MAX_DT)
	local now = os.clock()
	local current = session
	local moveState = Attributes.getString(player, P.MoveState, "Standing")
	if current == nil and VENT_STATES[moveState] ~= true then
		present(nil, player, dt, now)
		return
	end

	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local rootInstance = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local root = if rootInstance and rootInstance:IsA("BasePart") then rootInstance else nil
	if current and (current.character ~= character or current.root.Parent == nil or current.humanoid.Parent == nil) then
		release()
		current = nil
	end
	if character == nil or humanoid == nil or root == nil then
		present(current, player, dt, now)
		return
	end

	local lifeState = Attributes.getString(player, P.LifeState, "Lobby")
	local ball = character:FindFirstChild(VENT_COLLIDER_NAME)
	local decision = VentController.membership({
		engaged = current ~= nil,
		alive = humanoid.Health > 0 and lifeState ~= "Dead" and lifeState ~= "Spectating",
		moveState = moveState,
		collider = VentController.colliderMode(
			if ball and ball:IsA("BasePart") then ball.CollisionGroup else nil,
			root.CollisionGroup
		),
		locked = root.Anchored or Attributes.getString(player, P.ControlLock, "None") ~= "None",
	})
	if decision == "Release" then
		release()
		current = nil
	elseif decision == "Engage" then
		current = engage(character, humanoid, root, now)
		local locked = root.Anchored or Attributes.getString(player, P.ControlLock, "None") ~= "None"
		decision = if locked then "Hold" else "Drive"
	end
	if current then
		if decision == "Hold" then
			pause(current, now)
		else
			drive(current, player, dt, now)
		end
	end
	present(current, player, dt, now)
end

local function onPreSimulation(deltaTime: number)
	xpcall(frame, function(err: any)
		log.warnThrottled("frame", 5, "vent frame failed: %s\n%s", tostring(err), debug.traceback())
	end, deltaTime)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function VentController.Init()
	serviceTrove:Add(function()
		release()
		for _, watcher in grateWatchers do
			watcher:Disconnect()
		end
		table.clear(grateWatchers)
	end)
end

function VentController.Start()
	local player = localPlayer
	if not player then
		log.warn("no local player; vent crawling is not driven")
		return
	end
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.VentGrate), addGrate)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.VentGrate), removeGrate)
	for _, instance in CollectionService:GetTagged(Tags.VentGrate) do
		addGrate(instance)
	end
	serviceTrove:Connect(player.CharacterRemoving, function(model: Model)
		local current = session
		if current and current.character == model then
			release()
		end
	end)
	serviceTrove:Connect(RunService.PreSimulation, onPreSimulation)
end

function VentController.OnRunEnded()
	release()
	table.clear(stops)
end

--------------------------------------------------------------------------------
-- Beyond the contract
--------------------------------------------------------------------------------

-- True while this client is driving its character along a duct.
function VentController.IsInVent(): boolean
	return session ~= nil
end

-- The rail cursor (a copy) and the graph it runs on, while crawling.
function VentController.GetCursor(): (Cursor?, VentGraph.Graph?)
	local current = session
	local cursor = if current then current.cursor else nil
	local rail = if current then current.rail else nil
	if cursor == nil or rail == nil then
		return nil, nil
	end
	return { a = cursor.a, b = cursor.b, t = cursor.t }, rail.graph
end

return table.freeze(VentController)
