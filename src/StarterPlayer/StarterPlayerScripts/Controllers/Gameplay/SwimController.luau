--!strict
-- SwimController: swimming on this client, in part-based water (no Terrain: the PoolWater volumes). The server decides
-- who is in the water and judges the oxygen (FloodedPoolService, the same WaterRules); the client owns its character,
-- so the stroke is local physics the server validates, and everything the swimmer sees and hears is presented here.
--
-- Membership (membership, pure). A session runs while this client's root is in the water by WaterRules.locate (the
-- server's rule, so both sides agree), the character is alive and not crawling a duct, and through a climb out until
-- it lands. It starts the moment the root enters (the server's Swim mode follows within a tick; the movement mode hint
-- makes the predicted MoveState a swim state at once). While a ControlLock is held or the root is anchored (the
-- Creature's drag is server-owned; a jumpscare anchors) the session lets go of the body and the server moves it.
--
-- Physics. Engaging: InputContext "Swim" (Dive holds, Sprint swims freestyle), FirstPersonController
-- SetMoveModeHint("Swim"), the Humanoid in Physics with every state it could leave Physics for disabled (restored
-- exactly on release), and on the own root an Attachment carrying a VectorForce that cancels gravity (the water holds
-- the body up) and a LinearVelocity whose force is limited (stroke, pure): it pulls the body toward the stroke's
-- velocity no harder than the water's drag allows, more the faster the body moves against it, so a fall plunges in and
-- bobs back up, a stroke glides on and a turn swings wide.
--   * Surface states (Treading, Freestyle, a downed swimmer floating): horizontal velocity = Humanoid.MoveDirection
--     times the predicted MoveState's WalkSpeed (MovementController's table, the same the server allows), vertical
--     springs the root to WaterRules.floatRootY with a gentle bob (treading bobs slow and deep, freestyle quick).
--   * Underwater (Dive held): forward swims along the camera look, pitch included; strafing stays level; a duck dive
--     takes a swimmer who is not moving under DiveDepth; Space (the jump request) swims up; the body never breaches
--     the surface while the dive is held and never presses into the pool floor.
--   * An escape kick (Kick, StruggleController) adds upward speed for a moment.
-- Climbing out (climbTarget / climbPath, pure). At the surface (not diving), with the head up, a ledge just ahead (a
-- downward probe ClimbReach in front of the root finds a walkable top between ClimbMin and ClimbMax over the water:
-- the deck over the coping, a ladder's coping, a bridge fragment) and room to stand on it: Space climbs at once, and
-- swimming into the edge for ClimbPush seconds climbs too. The climb is a ClimbSeconds lift (an AlignPosition on the
-- root) up over the edge and onto the top, then the session releases onto the feet; the server's support check lets
-- the climb leave the water and exempts it from the fly check.
-- Presentation:
--   * Underwater view (underwaterAmount, waterline, pure; every render frame after the camera): the camera's eye
--     against the water surface. Under it: a camera-parented ColorCorrectionEffect (murky teal, dimmed, desaturated)
--     and BlurEffect, a murk overlay (ScreenGui gradient, darker toward the depths and closing in as the oxygen runs
--     low), AudioController.SetEnvironmentOverride("Underwater") (the muffled bus), the UnderwaterBed loop and the
--     panic breathing held (FirstPersonController.SuppressBreathing: nobody breathes under water). At the
--     surface the overlay is split at the projected waterline with a bright meniscus line, so a head bobbing at the
--     surface sees the lens half under. Breaking the surface with less than half the air left plays a SurfaceGasp.
--   * The lunge telegraph (Level 4 fairness: OneShot "LungeTelegraph", TelegraphSeconds before every lunge of the
--     Creature): at the lunge origin a stream of bubbles rises and a ripple ring pulses out on the surface above it
--     (the Creature growls there, a server cue), so a swimmer sees where it will come from and can climb out or swim off.
--   * Bubbles: cosmetic, client-only glass beads (no images) rising from the mouth: an exhale every ExhaleMin..Max
--     seconds under water (with the Bubbles sound), bursts on request (EmitBubbles: the struggle), and a trail from
--     every teammate's head under water; counts scale with the render budget.
--   * Strokes: SwimStroke for freestyle and WaterTread for treading, timed to each swimmer's speed, for this player and
--     every teammate in the water (3D at their roots); Splash for a fast entry (the server sends everyone else's).
--   * Hints (HUD.ShowHint, device-aware Strings): how to dive and swim fast on the first swim of a run, how to climb
--     out when an edge is in reach, and Hud.OxygenLow when the air runs short under water; a panic floor rises as the
--     oxygen falls under water.
-- Release (out of the water, a climb landing, a duct entered, death, respawn, run end): constraints destroyed,
-- Humanoid states restored (Running when it stands on something, else Freefall), hint, context and acoustics cleared.
--
-- Pure maths (tests/Specs/Pool.spec.luau): membership, bob, stroke, climbTarget, climbPath, underwaterAmount,
-- waterline, strokeInterval, exhaleDelay, murk, panicFloor.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local SoundSynthesizer = require(ReplicatedStorage.Shared.Audio.SoundSynthesizer)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Net = require(ReplicatedStorage.Shared.Net)
local Types = require(ReplicatedStorage.Shared.Types)
local WaterRules = require(ReplicatedStorage.Shared.Util.WaterRules)

local Controllers = script.Parent.Parent
local AudioController = require(Controllers.Core.AudioController)
local InputController = require(Controllers.Core.InputController)
local RenderBudgetController = require(Controllers.Core.RenderBudgetController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local MovementController = require(Controllers.FirstPerson.FirstPersonController.MovementController)
local HUD = require(Controllers.HUD)
local VentController = require(script.Parent.VentController)

local log = Log.new("SwimClient")

local P = Attributes.Player
local W = Attributes.World

type Volume = WaterRules.Volume

export type Membership = "Idle" | "Engage" | "Drive" | "Hold" | "Release"

export type MembershipInput = {
	engaged: boolean,
	alive: boolean,
	inVent: boolean,
	inWater: boolean,
	climbing: boolean,
	locked: boolean,
}

export type StrokeInput = {
	state: string, -- the predicted MoveState
	rootY: number,
	surface: number,
	bottom: number,
	velocity: Vector3, -- the root's assembly velocity now
	move: Vector3, -- Humanoid.MoveDirection (flat, length 0..1)
	look: Vector3, -- the camera look (unit)
	speed: number, -- WalkSpeed for the state
	time: number,
	rising: boolean, -- the jump request is held (swim up)
	kick: number, -- extra upward speed (an escape kick)
}

export type Stroke = {
	velocity: Vector3, -- LinearVelocity target
	accel: number, -- LinearVelocity force per unit mass (studs/s^2)
}

export type ClimbTarget = { edge: Vector3, stand: Vector3, top: number }

export type Waterline = { visible: boolean, y: number } -- viewport Y of the surface line (pixels)

type Session = {
	trove: Trove.Trove,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	attachment: Attachment,
	force: VectorForce,
	velocity: LinearVelocity,
	savedStates: { [Enum.HumanoidStateType]: boolean },
	volume: Volume,
	enteredAt: number,
	climb: { from: Vector3, target: ClimbTarget, startedAt: number, align: AlignPosition }?,
	paused: boolean,
	pushSince: number?,
	nextProbeAt: number,
	probe: ClimbTarget?,
	kickUntil: number,
	kickSpeed: number,
}

type Bubble = { part: BasePart, velocity: Vector3, born: number, life: number, surface: number, wobble: number }

type StrokeTrack = { nextAt: number }

local TOKEN = "Swim"
local SWIM_CONTEXT: Enums.InputContext = "Swim"
local UNDERWATER_ACOUSTICS: Enums.AcousticPreset = "Underwater"
local CONSTRAINT_NAME = "SwimForce"
local OVERLAY_NAME = "SwimOverlay"
local RENDER_STEP = "RovlocSwimFx"
local MAX_DT = 0.1

local PHYSICS = Enum.HumanoidStateType.Physics
local RUNNING = Enum.HumanoidStateType.Running
local FREEFALL = Enum.HumanoidStateType.Freefall
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

-- Water drag and floating
local BASE_ACCEL = 22 -- studs/s^2 the water lets a swimmer change speed at
local DRAG_GAIN = 6 -- extra accel per stud/s of velocity error (moving against the water is resisted harder)
local MAX_ACCEL = 420
local FLOAT_GAIN = 4 -- 1/s: how hard the vertical springs toward the float height
local SINK_MAX = 6 -- studs/s
local RISE_MAX = 6
local DIVE_DEPTH = 2.4 -- studs under the surface a duck dive takes the root
local DIVE_SPEED = 4.5
local DIVE_CEILING = 1.1 -- studs under the surface a diver's root is kept
local FLOOR_CLEARANCE = 1.3
local BOB: { [string]: { amplitude: number, frequency: number } } = {
	Treading = { amplitude = 0.12, frequency = 0.45 },
	Freestyle = { amplitude = 0.05, frequency = 1.1 },
	DownedCrawling = { amplitude = 0.05, frequency = 0.3 },
}
local DEFAULT_BOB = { amplitude = 0.1, frequency = 0.45 }

-- Climbing out
local CLIMB_REACH = 1.9 -- studs ahead of the root the ledge probe looks
local CLIMB_MIN = 0.1 -- a top this little over the surface is climbable
local CLIMB_MAX = 2.3
local CLIMB_STEP_IN = 1.2 -- studs past the edge the climber stands
local CLIMB_SECONDS = 0.7
local CLIMB_PUSH = 0.35 -- seconds of swimming into an edge that climbs it
local CLIMB_PUSH_DOT = 0.7
local CLIMB_JUMP_WINDOW = 0.3
local CLIMB_HEAD_DEPTH = 0.5 -- the eye may be at most this far under to climb
local PROBE_INTERVAL = 0.2
local STAND_SIZE = Vector3.new(2, 4.4, 2)
local STAND_LIFT = 0.35

-- View
local TINT = Color3.fromRGB(116, 186, 172)
local MURK = Color3.fromRGB(10, 34, 32)
local DEEP = Color3.fromRGB(2, 8, 9)
local LINE = Color3.fromRGB(196, 236, 230)
local BLUR_SIZE = 7
local WATERLINE_BAND = 0.35 -- studs either side of the surface the lens counts as half under
local WATERLINE_AHEAD = 1.4 -- studs ahead of the eye the waterline is projected
local MURK_TRANSPARENCY = 0.5
local LOW_AIR_FRACTION = 0.3
local LOW_AIR_REPEAT = 8
local GASP_BELOW = 0.5
local PANIC_TOKEN = "Swim"
local PANIC_FROM = 0.6 -- oxygen share under which the heart starts to race under water
local PANIC_MAX = 0.75

-- Bubbles
local EXHALE_MIN = 2.4
local EXHALE_MAX = 4
local BUBBLE_POOL = 64
local TELEGRAPH_BUBBLE_EVERY = 0.06
local TELEGRAPH_SPREAD = 0.7
local RIPPLE_PULSE = 0.6
local RIPPLE_RADIUS = 4.5
local RIPPLE_RINGS = 4
local RIPPLE_COLOR = Color3.fromRGB(184, 219, 214)
local BUBBLE_LIFE = 3
local BUBBLE_RISE_MIN = 2.6
local BUBBLE_RISE_MAX = 4.6
local TEAMMATE_BUBBLES = 3.2 -- seconds between a teammate's trails

-- Strokes
local FREESTYLE_STROKE = 0.55
local TREAD_STROKE = 1.25
local TREAD_IDLE = 2.6
local STROKE_MOVING = 1.5 -- studs/s of horizontal speed that count as stroking
local SPLASH_ENTRY = 9 -- studs/s of fall that make the entry a splash

-- Hints
local SWIM_HINT_SECONDS = 6
local CLIMB_HINT_SECONDS = 3
local CLIMB_HINT_REPEAT = 20

local SwimController = {}

SwimController.Name = "SwimController"
SwimController.DiveDepth = DIVE_DEPTH
SwimController.ClimbReach = CLIMB_REACH
SwimController.ClimbMin = CLIMB_MIN
SwimController.ClimbMax = CLIMB_MAX
SwimController.ClimbSeconds = CLIMB_SECONDS
SwimController.ClimbPush = CLIMB_PUSH
SwimController.WaterlineBand = WATERLINE_BAND
SwimController.ExhaleMin = EXHALE_MIN
SwimController.ExhaleMax = EXHALE_MAX

local localPlayer: Player? = Players.LocalPlayer
local serviceTrove = Trove.new()
local session: Session? = nil
local volumes: { Volume }? = nil
local lastJumpAt = -math.huge
local random = Random.new()
local hintedSwim = false
local climbHintAt = -math.huge
local lowAirHintAt = -math.huge
local panicHeld = false
local underwater = 0 -- the camera's underwater amount this frame
local wasUnder = false
local nextExhaleAt = math.huge
local bubbles: { Bubble } = {}

type Telegraph = {
	origin: Vector3,
	surface: number,
	startedAt: number, -- os.clock()
	endsAt: number,
	nextBubbleAt: number,
	ring: Part,
	stroke: UIStroke,
}
local telegraphs: { Telegraph } = {}
local freeBubbles: { BasePart } = {}
local strokeTracks: { [Player]: StrokeTrack } = {}
local trailAt: { [Player]: number } = {}
local lastRootY: number? = nil
local lastRootAt = 0

-- View instances (made on first use)
local tint: ColorCorrectionEffect? = nil
local blur: BlurEffect? = nil
local overlay: ScreenGui? = nil
local murkFrame: Frame? = nil
local murkGradient: UIGradient? = nil
local lineFrame: Frame? = nil
local bedVoice: SoundSynthesizer.Voice? = nil
local acousticsHeld = false

--------------------------------------------------------------------------------
-- Pure maths
--------------------------------------------------------------------------------

-- What the session does this frame (see the header).
function SwimController.membership(input: MembershipInput): Membership
	if not input.alive or input.inVent then
		return if input.engaged then "Release" else "Idle"
	end
	if not (input.inWater or (input.engaged and input.climbing)) then
		return if input.engaged then "Release" else "Idle"
	end
	if not input.engaged then
		return "Engage"
	end
	return if input.locked then "Hold" else "Drive"
end

-- The float height's bob (studs) for `state` at time `t`.
function SwimController.bob(state: string, t: number): number
	local spec = BOB[state] or DEFAULT_BOB
	return spec.amplitude * math.sin(2 * math.pi * spec.frequency * t)
end

-- The stroke this frame (see the header): the velocity the water carries the root toward and how hard.
function SwimController.stroke(input: StrokeInput): Stroke
	local move = MathUtil.flat(input.move)
	if move.Magnitude > 1 then
		move = move.Unit
	end
	local target: Vector3
	if input.state == "Underwater" then
		local flatLook = MathUtil.flat(input.look)
		flatLook = if flatLook.Magnitude > 1e-3 then flatLook.Unit else Vector3.new(0, 0, -1)
		local forward = move:Dot(flatLook)
		local strafe = move - flatLook * forward
		local look = if input.look.Magnitude > 1e-3 then input.look.Unit else flatLook
		local direction = look * forward + strafe
		target = direction * input.speed
		local depth = input.surface - input.rootY
		if move.Magnitude < 0.1 then
			target = Vector3.new(target.X, if depth < DIVE_DEPTH then -DIVE_SPEED else 0, target.Z)
		end
		if input.rising then
			target = Vector3.new(target.X, math.max(target.Y, input.speed), target.Z)
		end
		local ceiling = input.surface - DIVE_CEILING
		if input.rootY > ceiling - 0.5 and target.Y > 0 then
			target = Vector3.new(target.X, math.min(target.Y, (ceiling - input.rootY) * FLOAT_GAIN), target.Z)
		end
		-- Level speed never beats the state's WalkSpeed (the server's check is horizontal).
		local flat = MathUtil.flat(target)
		if flat.Magnitude > input.speed then
			flat = flat.Unit * input.speed
			target = Vector3.new(flat.X, target.Y, flat.Z)
		end
	else
		local floatY = WaterRules.floatRootY(input.surface, input.state) + SwimController.bob(input.state, input.time)
		local vertical = math.clamp((floatY - input.rootY) * FLOAT_GAIN, -SINK_MAX, RISE_MAX)
		local horizontal = move * input.speed
		target = Vector3.new(horizontal.X, vertical, horizontal.Z)
	end
	if input.kick > 0 then
		target = Vector3.new(target.X, math.max(target.Y, input.kick), target.Z)
	end
	if input.rootY < input.bottom + FLOOR_CLEARANCE and target.Y < 0 then
		target = Vector3.new(target.X, 0, target.Z)
	end
	local error = (target - input.velocity).Magnitude
	return { velocity = target, accel = math.min(MAX_ACCEL, BASE_ACCEL + DRAG_GAIN * error) }
end

-- The climb onto a walkable top at height `top` found `reach` ahead of a root at `root` facing `forward` (flat unit),
-- for a character whose root stands `rootHeight` over its floor, from water whose surface is `surface`; nil when the
-- top is not between ClimbMin and ClimbMax over the water.
function SwimController.climbTarget(
	root: Vector3,
	forward: Vector3,
	top: number,
	surface: number,
	rootHeight: number,
	reach: number
): ClimbTarget?
	local height = top - surface
	if height < CLIMB_MIN or height > CLIMB_MAX then
		return nil
	end
	local flat = MathUtil.flat(forward)
	if flat.Magnitude < 1e-3 then
		return nil
	end
	local direction = flat.Unit
	local edge = Vector3.new(root.X, top, root.Z) + direction * reach
	local stand = edge + direction * CLIMB_STEP_IN + Vector3.new(0, rootHeight, 0)
	return { edge = edge, stand = stand, top = top }
end

-- Where the climbing root is `alpha` (0..1) of the way through a climb from `from`: hauled up over the edge first
-- (rising to just over the top), then over it and onto the feet.
function SwimController.climbPath(from: Vector3, target: ClimbTarget, alpha: number): Vector3
	local a = MathUtil.clamp01(alpha)
	local over = Vector3.new(from.X, target.stand.Y + 0.15, from.Z)
		:Lerp(Vector3.new(target.edge.X, target.stand.Y + 0.15, target.edge.Z), 0.35)
	if a < 0.5 then
		local u = MathUtil.smoothstep(0, 1, a / 0.5)
		return from:Lerp(over, u)
	end
	local u = MathUtil.smoothstep(0, 1, (a - 0.5) / 0.5)
	return over:Lerp(target.stand, u)
end

-- How far under the camera is (0 = in the air, 1 = under) for an eye `depth` studs below the surface.
function SwimController.underwaterAmount(depth: number): number
	return MathUtil.smoothstep(-0.05, 0.25, depth)
end

-- The waterline on screen: the surface plane `aheadY` (the viewport Y of the surface point WaterlineAhead studs in
-- front of the eye), shown while the eye is within WaterlineBand of the surface and that point is in front of the
-- camera. `viewportY` is the screen height.
function SwimController.waterline(depth: number, aheadY: number, inFront: boolean, viewportY: number): Waterline
	if math.abs(depth) > WATERLINE_BAND or not inFront then
		return { visible = false, y = if depth > 0 then 0 else viewportY }
	end
	return { visible = true, y = math.clamp(aheadY, 0, viewportY) }
end

-- Seconds between stroke sounds for a swimmer in `state` moving at `speed` studs/s (nil: silent).
function SwimController.strokeInterval(state: string, speed: number): number?
	if state == "Freestyle" then
		return if speed >= STROKE_MOVING then FREESTYLE_STROKE else TREAD_IDLE
	elseif state == "Treading" or state == "DownedCrawling" then
		return if speed >= STROKE_MOVING then TREAD_STROKE else TREAD_IDLE
	end
	return nil
end

-- Seconds until the next exhale under water (sooner as the air runs out).
function SwimController.exhaleDelay(oxygenFraction: number, roll: number): number
	local base = EXHALE_MIN + (EXHALE_MAX - EXHALE_MIN) * MathUtil.clamp01(roll)
	return base * (0.45 + 0.55 * MathUtil.clamp01(oxygenFraction))
end

-- The murk overlay's transparency for an underwater amount and the oxygen share left (it closes in as air runs out).
function SwimController.murk(amount: number, oxygenFraction: number): number
	local base = 1 - (1 - MURK_TRANSPARENCY) * MathUtil.clamp01(amount)
	local starving = 1 - MathUtil.smoothstep(0.05, 0.45, oxygenFraction)
	return math.clamp(base - 0.35 * starving * MathUtil.clamp01(amount), 0, 1)
end

-- The panic floor while under water with `oxygenFraction` of the air left (nil: no floor).
function SwimController.panicFloor(oxygenFraction: number, under: boolean): number?
	if not under or oxygenFraction >= PANIC_FROM then
		return nil
	end
	return PANIC_MAX * (1 - oxygenFraction / PANIC_FROM)
end

--------------------------------------------------------------------------------
-- Water volumes (the server's rule: PoolWater parts under the school; duct floods are crawled)
--------------------------------------------------------------------------------

local function ductRooms(levelId: string): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local layout = Builder.getLayout(levelId)
	if layout then
		for _, room in layout.rooms do
			if room.kind == "Chase" then
				out[room.id] = true
			end
		end
	end
	return out
end

local function scanVolumes(): { Volume }
	local cached = volumes
	if cached then
		return cached
	end
	local out: { Volume } = {}
	local ducts: { [string]: { [string]: boolean } } = {}
	for _, instance in CollectionService:GetTagged(Tags.PoolWater) do
		if not instance:IsA("BasePart") then
			continue
		end
		local levelId = Attributes.getString(instance, W.LevelId, "")
		local rooms = ducts[levelId] or ductRooms(levelId)
		ducts[levelId] = rooms
		local zone = Attributes.getString(instance, W.ZoneId, "")
		local id = Attributes.getString(instance, W.TriggerId, instance.Name)
		table.insert(out, WaterRules.volumeOf(id, instance.CFrame, instance.Size, rooms[zone] == true, instance))
	end
	volumes = out
	return out
end

--------------------------------------------------------------------------------
-- Audio + bubbles
--------------------------------------------------------------------------------

local function play(preset: string, options: SoundSynthesizer.PlayOptions?): SoundSynthesizer.Voice?
	local ok, voice = pcall(AudioController.PlayLocal, preset, options)
	if not ok then
		log.warnThrottled("play:" .. preset, 10, "%s failed: %s", preset, tostring(voice))
		return nil
	end
	return voice
end

local function bubbleFolder(): Instance?
	return Workspace.CurrentCamera
end

local function takeBubble(): BasePart?
	local part = table.remove(freeBubbles)
	if part then
		return part
	end
	if #bubbles >= BUBBLE_POOL then
		return nil
	end
	local made = Instance.new("Part")
	made.Name = "SwimBubble"
	made.Shape = Enum.PartType.Ball
	made.Material = Enum.Material.Glass
	made.Color = Color3.fromRGB(206, 236, 238)
	made.Transparency = 0.35
	made.Anchored = true
	made.CanCollide = false
	made.CanQuery = false
	made.CanTouch = false
	made.CastShadow = false
	return made
end

local function spawnBubbles(origin: Vector3, surface: number, count: number, spread: number)
	local folder = bubbleFolder()
	if not folder then
		return
	end
	local scale = RenderBudgetController.GetBudget().particleScale
	local total = math.max(1, math.floor(count * math.clamp(scale, 0.25, 1.5) + 0.5))
	for _ = 1, total do
		local part = takeBubble()
		if not part then
			return
		end
		local size = random:NextNumber(0.06, 0.2)
		part.Size = Vector3.new(size, size, size)
		local offset = Vector3.new(random:NextNumber(-spread, spread), 0, random:NextNumber(-spread, spread))
		part.CFrame = CFrame.new(origin + offset)
		part.Parent = folder
		table.insert(bubbles, {
			part = part,
			velocity = Vector3.new(0, random:NextNumber(BUBBLE_RISE_MIN, BUBBLE_RISE_MAX), 0),
			born = os.clock(),
			life = BUBBLE_LIFE * random:NextNumber(0.7, 1),
			surface = surface,
			wobble = random:NextNumber(0, math.pi * 2),
		})
	end
end

local function stepBubbles(dt: number, now: number)
	for index = #bubbles, 1, -1 do
		local bubble = bubbles[index]
		local part = bubble.part
		local age = now - bubble.born
		local position = part.CFrame.Position
		if age >= bubble.life or position.Y >= bubble.surface or part.Parent == nil then
			table.remove(bubbles, index)
			part.Parent = nil
			table.insert(freeBubbles, part)
			continue
		end
		local sway = Vector3.new(math.sin(age * 7 + bubble.wobble), 0, math.cos(age * 6 + bubble.wobble)) * 0.35
		part.CFrame = CFrame.new(position + (bubble.velocity + sway) * dt)
	end
end

-- A flat ripple ring for a lunge telegraph: an invisible plate with a round stroke on its top face.
local function makeRing(): (Part, UIStroke)
	local ring = Instance.new("Part")
	ring.Name = "LungeRipple"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Transparency = 1
	ring.Size = Vector3.new(1, 0.05, 1)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = ring
	local circle = Instance.new("Frame")
	circle.BackgroundTransparency = 1
	circle.Size = UDim2.fromScale(1, 1)
	circle.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = circle
	local stroke = Instance.new("UIStroke")
	stroke.Color = RIPPLE_COLOR
	stroke.Thickness = 6
	stroke.Transparency = 1
	stroke.Parent = circle
	return ring, stroke
end

-- The Creature's lunge is coming from `origin` in `seconds` (from server time `startAt`).
local function telegraph(origin: Vector3, seconds: number, startAt: number)
	local folder = bubbleFolder()
	if not folder then
		return
	end
	local water = WaterRules.volumeAround(scanVolumes(), origin, 1)
	local surface = if water then water.surface else origin.Y + 2.5
	local start = os.clock() + math.max(0, startAt - Workspace:GetServerTimeNow())
	if #telegraphs >= RIPPLE_RINGS then
		local oldest = table.remove(telegraphs, 1)
		if oldest then
			oldest.ring:Destroy()
		end
	end
	local ring, stroke = makeRing()
	ring.CFrame = CFrame.new(origin.X, surface + 0.04, origin.Z)
	ring.Parent = folder
	table.insert(telegraphs, {
		origin = origin,
		surface = surface,
		startedAt = start,
		endsAt = start + math.max(0, seconds),
		nextBubbleAt = start,
		ring = ring,
		stroke = stroke,
	})
end

local function stepTelegraphs(now: number)
	for index = #telegraphs, 1, -1 do
		local t = telegraphs[index]
		if now > t.endsAt + RIPPLE_PULSE then
			t.ring:Destroy()
			table.remove(telegraphs, index)
			continue
		end
		if now < t.startedAt then
			continue
		end
		if now < t.endsAt then
			while t.nextBubbleAt <= now do
				t.nextBubbleAt += TELEGRAPH_BUBBLE_EVERY
				spawnBubbles(t.origin, t.surface, 2, TELEGRAPH_SPREAD)
			end
		end
		-- pulses out from the origin over the telegraph, the last one fading after it
		local age = now - t.startedAt
		local phase = (age % RIPPLE_PULSE) / RIPPLE_PULSE
		local fading = if now > t.endsAt then 1 - math.clamp((now - t.endsAt) / RIPPLE_PULSE, 0, 1) else 1
		local radius = 0.6 + (RIPPLE_RADIUS - 0.6) * phase
		t.ring.Size = Vector3.new(radius * 2, 0.05, radius * 2)
		t.stroke.Transparency = 1 - 0.55 * (1 - phase) * fading
	end
end

local function clearTelegraphs()
	for _, t in telegraphs do
		t.ring:Destroy()
	end
	table.clear(telegraphs)
end

local function onOneShot(payload: any)
	if type(payload) ~= "table" or payload.kind ~= "LungeTelegraph" then
		return
	end
	local args = payload.args
	if type(args) ~= "table" then
		return
	end
	local origin, seconds, startAt = args.origin, args.seconds, payload.startAt
	if typeof(origin) == "Vector3" and type(seconds) == "number" and type(startAt) == "number" then
		telegraph(origin, seconds, startAt)
	end
end

local function clearBubbles()
	for _, bubble in bubbles do
		bubble.part:Destroy()
	end
	table.clear(bubbles)
	for _, part in freeBubbles do
		part:Destroy()
	end
	table.clear(freeBubbles)
end

--------------------------------------------------------------------------------
-- View
--------------------------------------------------------------------------------

local function ensureView(camera: Camera)
	local cc = tint
	if not cc or cc.Parent ~= camera then
		if cc then
			cc:Destroy()
		end
		local made = Instance.new("ColorCorrectionEffect")
		made.Name = "SwimTint"
		made.Enabled = false
		made.Parent = camera
		tint = made
	end
	local bl = blur
	if not bl or bl.Parent ~= camera then
		if bl then
			bl:Destroy()
		end
		local made = Instance.new("BlurEffect")
		made.Name = "SwimBlur"
		made.Size = 0
		made.Enabled = false
		made.Parent = camera
		blur = made
	end
	local gui = overlay
	local player = localPlayer
	if (not gui or gui.Parent == nil) and player then
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return
		end
		local screen = Instance.new("ScreenGui")
		screen.Name = OVERLAY_NAME
		screen.ResetOnSpawn = false
		screen.IgnoreGuiInset = true
		screen.DisplayOrder = -2
		screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		local murk = Instance.new("Frame")
		murk.Name = "Murk"
		murk.BorderSizePixel = 0
		murk.BackgroundColor3 = MURK
		murk.BackgroundTransparency = 1
		murk.Size = UDim2.fromScale(1, 1)
		murk.Parent = screen
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Color = ColorSequence.new(MURK:Lerp(TINT, 0.25), DEEP)
		gradient.Parent = murk
		local line = Instance.new("Frame")
		line.Name = "Waterline"
		line.BorderSizePixel = 0
		line.BackgroundColor3 = LINE
		line.BackgroundTransparency = 1
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Size = UDim2.new(1.2, 0, 0, 3)
		line.Position = UDim2.fromScale(0.5, 0.5)
		line.Parent = screen
		local lineGradient = Instance.new("UIGradient")
		lineGradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, 0.35),
			NumberSequenceKeypoint.new(0.5, 0.15),
			NumberSequenceKeypoint.new(0.8, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		lineGradient.Parent = line
		screen.Parent = playerGui
		overlay = screen
		murkFrame = murk
		murkGradient = gradient
		lineFrame = line
	end
end

local function setAcoustics(under: boolean)
	if under == acousticsHeld then
		return
	end
	acousticsHeld = under
	AudioController.SetEnvironmentOverride(if under then UNDERWATER_ACOUSTICS else nil)
	-- Nobody breathes under water: the panic breathing loop holds while the head is under (the heart goes on).
	FirstPersonController.SuppressBreathing(PANIC_TOKEN, under)
	if under then
		if not bedVoice then
			bedVoice = play("UnderwaterBed", { looped = true, fadeIn = 0.25 })
		end
	else
		local voice = bedVoice
		bedVoice = nil
		if voice then
			voice:Stop(0.4)
		end
	end
end

local function oxygenFraction(player: Player): number
	local max = Attributes.getNumber(player, P.OxygenMax, GameConfig.OxygenMax)
	local value = Attributes.readMeter(player, P.Oxygen, P.OxygenRate, P.OxygenAt, max, Workspace:GetServerTimeNow())
	return if max > 0 then MathUtil.clamp01(value / max) else 1
end

local function hideView()
	local cc = tint
	if cc then
		cc.Enabled = false
	end
	local bl = blur
	if bl then
		bl.Enabled = false
	end
	local murk = murkFrame
	if murk then
		murk.BackgroundTransparency = 1
	end
	local line = lineFrame
	if line then
		line.BackgroundTransparency = 1
	end
	setAcoustics(false)
	underwater = 0
end

local function renderView(dt: number)
	local player = localPlayer
	local camera = Workspace.CurrentCamera
	if not player or not camera then
		return
	end
	local now = os.clock()
	stepTelegraphs(now)
	stepBubbles(dt, now)
	local eye = camera.CFrame.Position
	local volume = WaterRules.volumeAround(scanVolumes(), eye, WATERLINE_BAND + 0.5)
	if not volume then
		if underwater > 0 or acousticsHeld then
			hideView()
		end
		if wasUnder then
			wasUnder = false
			nextExhaleAt = math.huge
		end
		if panicHeld then
			panicHeld = false
			FirstPersonController.SetPanicFloor(PANIC_TOKEN, nil)
		end
		return
	end
	ensureView(camera)
	local depth = volume.surface - eye.Y
	local amount = SwimController.underwaterAmount(depth)
	underwater = amount
	local air = oxygenFraction(player)
	local under = depth > 0.15
	local cc, bl = tint, blur
	if cc then
		cc.Enabled = amount > 0.01
		cc.TintColor = Color3.new(1, 1, 1):Lerp(TINT, amount)
		cc.Brightness = -0.08 * amount - 0.12 * amount * (1 - air)
		cc.Contrast = 0.06 * amount
		cc.Saturation = -0.4 * amount
	end
	if bl then
		bl.Enabled = amount > 0.01
		bl.Size = BLUR_SIZE * amount * (1 + 0.5 * (1 - air))
	end
	local viewport = camera.ViewportSize
	local look = MathUtil.flat(camera.CFrame.LookVector)
	local ahead = Vector3.new(eye.X, volume.surface, eye.Z)
		+ (if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)) * WATERLINE_AHEAD
	local screen, inFront = camera:WorldToViewportPoint(ahead)
	local line = SwimController.waterline(depth, screen.Y, inFront and screen.Z > 0, viewport.Y)
	local murk, gradient, lineGui = murkFrame, murkGradient, lineFrame
	if murk and gradient and lineGui then
		local transparency = SwimController.murk(if line.visible then 1 else amount, air)
		if line.visible then
			murk.Position = UDim2.fromOffset(0, line.y)
			murk.Size = UDim2.new(1, 0, 1, math.max(0, viewport.Y - line.y))
			lineGui.Position = UDim2.fromOffset(viewport.X / 2, line.y)
			lineGui.Rotation = math.deg(math.asin(math.clamp(camera.CFrame.RightVector.Y, -1, 1)))
			lineGui.BackgroundTransparency = 0.2
		else
			murk.Position = UDim2.fromScale(0, 0)
			murk.Size = UDim2.fromScale(1, 1)
			lineGui.BackgroundTransparency = 1
		end
		murk.BackgroundTransparency = transparency
		gradient.Offset = Vector2.new(0, -0.25 * math.clamp(depth / 6, 0, 1))
	end
	setAcoustics(under)

	-- Breathing under water: exhales, the surfacing gasp, the panic floor, the low-air hint.
	if under and not wasUnder then
		nextExhaleAt = now + SwimController.exhaleDelay(air, random:NextNumber())
	elseif not under and wasUnder and air < GASP_BELOW then
		play("SurfaceGasp", { volume = 0.9 + 0.6 * (GASP_BELOW - air) })
	end
	wasUnder = under
	if under and now >= nextExhaleAt then
		local mouth = eye + camera.CFrame.LookVector * 0.6 - Vector3.new(0, 0.2, 0)
		spawnBubbles(mouth, volume.surface, random:NextInteger(4, 7), 0.12)
		play("Bubbles", { position = mouth, volume = 0.7 })
		nextExhaleAt = now + SwimController.exhaleDelay(air, random:NextNumber())
	end
	local floor = SwimController.panicFloor(air, under)
	if floor then
		panicHeld = true
		FirstPersonController.SetPanicFloor(PANIC_TOKEN, floor)
	elseif panicHeld then
		panicHeld = false
		FirstPersonController.SetPanicFloor(PANIC_TOKEN, nil)
	end
	if under and air < LOW_AIR_FRACTION and now - lowAirHintAt >= LOW_AIR_REPEAT then
		lowAirHintAt = now
		HUD.ShowHint("Hud.OxygenLow", 2)
	end
end

--------------------------------------------------------------------------------
-- Strokes (this player and teammates) + teammates' bubbles
--------------------------------------------------------------------------------

local function stepStrokes(now: number)
	local camera = Workspace.CurrentCamera
	local listener = if camera then camera.CFrame.Position else nil
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local state = Attributes.getString(player, P.MoveState, "Standing")
		if player == localPlayer then
			state = FirstPersonController.GetPredictedMoveState()
		end
		if not (root and root:IsA("BasePart")) then
			strokeTracks[player] = nil
			continue
		end
		local speed = MathUtil.flat(root.AssemblyLinearVelocity).Magnitude
		local interval = SwimController.strokeInterval(state, speed)
		if player == localPlayer and session == nil then
			interval = nil
		end
		if interval == nil then
			strokeTracks[player] = nil
		else
			local track = strokeTracks[player]
			if not track then
				track = { nextAt = now + random:NextNumber(0, interval) }
				strokeTracks[player] = track
			end
			if now >= track.nextAt then
				track.nextAt = now + interval * random:NextNumber(0.85, 1.15)
				local preset = if state == "Freestyle" and speed >= STROKE_MOVING then "SwimStroke" else "WaterTread"
				local quiet = speed < STROKE_MOVING
				play(preset, { attach = root :: Instance, volume = if quiet then 0.5 else 1 })
			end
		end
		-- A teammate under water trails bubbles.
		if player ~= localPlayer and state == "Underwater" and listener then
			if (root.Position - listener).Magnitude < 60 and now >= (trailAt[player] or 0) then
				trailAt[player] = now + TEAMMATE_BUBBLES * random:NextNumber(0.8, 1.2)
				local water = WaterRules.volumeAround(scanVolumes(), root.Position, 1)
				if water then
					spawnBubbles(root.Position + Vector3.new(0, 1.2, 0), water.surface, random:NextInteger(3, 5), 0.2)
				end
			end
		end
	end
	for player in table.clone(strokeTracks) do
		if player.Parent ~= Players then
			strokeTracks[player] = nil
			trailAt[player] = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Session
--------------------------------------------------------------------------------

local function rootHeightOf(humanoid: Humanoid, root: BasePart): number
	return humanoid.HipHeight + root.Size.Y / 2
end

local function deviceKey(prefix: string): string
	return prefix .. "." .. InputController.GetDevice()
end

local function engage(character: Model, humanoid: Humanoid, root: BasePart, volume: Volume, now: number): Session
	local trove = Trove.new()
	local attachment = Instance.new("Attachment")
	attachment.Name = CONSTRAINT_NAME
	attachment.Parent = root
	trove:Add(attachment)

	local force = Instance.new("VectorForce")
	force.Name = CONSTRAINT_NAME
	force.Attachment0 = attachment
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.new(0, root.AssemblyMass * Workspace.Gravity, 0)
	force.Parent = root
	trove:Add(force)

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = CONSTRAINT_NAME
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	velocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	velocity.ForceLimitsEnabled = true
	velocity.MaxForce = root.AssemblyMass * BASE_ACCEL
	velocity.VectorVelocity = root.AssemblyLinearVelocity
	velocity.Parent = root
	trove:Add(velocity)

	local saved: { [Enum.HumanoidStateType]: boolean } = {}
	for _, state in SUSPENDED_STATES do
		saved[state] = humanoid:GetStateEnabled(state)
		humanoid:SetStateEnabled(state, false)
	end
	humanoid:ChangeState(PHYSICS)

	FirstPersonController.SetMoveModeHint("Swim")
	InputController.PushContext(SWIM_CONTEXT, TOKEN)

	-- A fall or a jump into the water: the splash (the server sends it to everyone else).
	local previousY = lastRootY
	if previousY and now - lastRootAt < 0.5 and now > lastRootAt then
		local fall = (previousY - root.Position.Y) / (now - lastRootAt)
		local point = Vector3.new(root.Position.X, volume.surface, root.Position.Z)
		if fall >= SPLASH_ENTRY then
			play("Splash", { position = point, volume = 1.2 })
			spawnBubbles(point - Vector3.new(0, 1, 0), volume.surface, 8, 0.6)
		else
			play("WaterTread", { position = point, volume = 0.8 })
		end
	end
	if not hintedSwim then
		hintedSwim = true
		HUD.ShowHint(deviceKey("Hud.SwimHint"), SWIM_HINT_SECONDS)
	end

	local current: Session = {
		trove = trove,
		character = character,
		humanoid = humanoid,
		root = root,
		attachment = attachment,
		force = force,
		velocity = velocity,
		savedStates = saved,
		volume = volume,
		enteredAt = now,
		climb = nil,
		paused = false,
		pushSince = nil,
		nextProbeAt = now,
		probe = nil,
		kickUntil = 0,
		kickSpeed = 0,
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
	current.trove:Destroy()
	local climb = current.climb
	if climb then
		climb.align:Destroy()
	end
	local humanoid = current.humanoid
	if humanoid.Parent ~= nil then
		for state, enabled in current.savedStates do
			humanoid:SetStateEnabled(state, enabled)
		end
		humanoid.Jump = false
		if humanoid.Health > 0 and humanoid:GetState() == PHYSICS then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { current.character }
			params.CollisionGroup = "Default"
			local root = current.root
			local reach = rootHeightOf(humanoid, root) + 0.6
			local grounded = Workspace:Raycast(root.Position, Vector3.new(0, -reach, 0), params) ~= nil
			humanoid:ChangeState(if grounded then RUNNING else FREEFALL)
		end
	end
	FirstPersonController.SetMoveModeHint(nil)
	InputController.PopContext(TOKEN)
end

local function setDriving(current: Session, on: boolean)
	if current.force.Enabled ~= on then
		current.force.Enabled = on
	end
	if current.velocity.Enabled ~= on then
		current.velocity.Enabled = on
	end
end

-- The ledge ahead a swimmer could climb onto (nil when there is none, or no room to stand on it).
local function probeClimb(current: Session): ClimbTarget?
	local root = current.root
	local forward = MathUtil.flat(root.CFrame.LookVector)
	if forward.Magnitude < 1e-3 then
		return nil
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { current.character }
	for _, other in Players:GetPlayers() do
		local model = other.Character
		if model and model ~= current.character then
			table.insert(exclude, model)
		end
	end
	params.FilterDescendantsInstances = exclude
	params.CollisionGroup = "Players"
	params.RespectCanCollide = true
	local surface = current.volume.surface
	local origin = Vector3.new(root.Position.X, surface + CLIMB_MAX + 0.8, root.Position.Z) + forward.Unit * CLIMB_REACH
	local hit = Workspace:Raycast(origin, Vector3.new(0, -(CLIMB_MAX + 1.4), 0), params)
	if not hit or hit.Normal.Y < 0.7 then
		return nil
	end
	local target = SwimController.climbTarget(
		root.Position,
		forward,
		hit.Position.Y,
		surface,
		rootHeightOf(current.humanoid, root),
		CLIMB_REACH
	)
	if not target then
		return nil
	end
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = exclude
	overlap.CollisionGroup = "Players"
	local standBox = CFrame.new(target.stand - Vector3.new(0, rootHeightOf(current.humanoid, root) - STAND_LIFT, 0))
		* CFrame.new(0, STAND_SIZE.Y / 2, 0)
	if #Workspace:GetPartBoundsInBox(standBox, STAND_SIZE, overlap) > 0 then
		return nil
	end
	return target
end

local function startClimb(current: Session, target: ClimbTarget, now: number)
	local align = Instance.new("AlignPosition")
	align.Name = CONSTRAINT_NAME
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = current.attachment
	align.RigidityEnabled = false
	align.Responsiveness = 60
	align.MaxForce = 1e7
	align.MaxVelocity = 24
	align.ApplyAtCenterOfMass = true
	align.Position = current.root.Position
	align.Parent = current.root
	current.velocity.Enabled = false
	current.climb = { from = current.root.Position, target = target, startedAt = now, align = align }
	play("ClimbOut", { attach = current.root :: Instance })
	HUD.ClearHint(deviceKey("Hud.ClimbOut"))
end

local function drive(current: Session, player: Player, now: number)
	local root = current.root
	local humanoid = current.humanoid
	if current.paused then
		current.paused = false
	end
	if humanoid:GetState() ~= PHYSICS then
		humanoid:ChangeState(PHYSICS)
	end
	local climb = current.climb
	if climb then
		current.force.Enabled = true
		local alpha = (now - climb.startedAt) / CLIMB_SECONDS
		climb.align.Position = SwimController.climbPath(climb.from, climb.target, alpha)
		if alpha >= 1 then
			release()
		end
		return
	end
	setDriving(current, true)
	local mass = root.AssemblyMass
	current.force.Force = Vector3.new(0, mass * Workspace.Gravity, 0)

	local state: Enums.MoveState = FirstPersonController.GetPredictedMoveState()
	local yaw, pitch = FirstPersonController.GetLook()
	local rising = now - lastJumpAt <= CLIMB_JUMP_WINDOW
	local stroke = SwimController.stroke({
		state = state,
		rootY = root.Position.Y,
		surface = current.volume.surface,
		bottom = current.volume.bottom,
		velocity = root.AssemblyLinearVelocity,
		move = humanoid.MoveDirection,
		look = MathUtil.vectorFromYawPitch(yaw, pitch),
		speed = MovementController.speedFor(state),
		time = Workspace:GetServerTimeNow() + (player.UserId % 97) * 0.13,
		rising = rising and state == "Underwater",
		kick = if now < current.kickUntil then current.kickSpeed else 0,
	})
	current.velocity.VectorVelocity = stroke.velocity
	current.velocity.MaxForce = mass * stroke.accel

	-- Climbing out: probe the edge ahead a few times a second while at the surface.
	local eyeDepth = WaterRules.eyeDepth(state, root.Position.Y, current.volume.surface)
	local canClimb = state ~= "Underwater" and state ~= "Grabbed" and eyeDepth <= CLIMB_HEAD_DEPTH
	if not canClimb then
		current.probe = nil
		current.pushSince = nil
		return
	end
	if now >= current.nextProbeAt then
		current.nextProbeAt = now + PROBE_INTERVAL
		current.probe = probeClimb(current)
		if current.probe and now - climbHintAt >= CLIMB_HINT_REPEAT then
			climbHintAt = now
			HUD.ShowHint(deviceKey("Hud.ClimbOut"), CLIMB_HINT_SECONDS)
		end
	end
	local target = current.probe
	if not target then
		current.pushSince = nil
		return
	end
	local forward = MathUtil.flat(root.CFrame.LookVector)
	local pushing = forward.Magnitude > 1e-3 and humanoid.MoveDirection:Dot(forward.Unit) >= CLIMB_PUSH_DOT
	if pushing then
		current.pushSince = current.pushSince or now
	else
		current.pushSince = nil
	end
	local pushedLong = current.pushSince ~= nil and now - (current.pushSince :: number) >= CLIMB_PUSH
	if rising or pushedLong then
		startClimb(current, target, now)
	end
end

local function pause(current: Session)
	setDriving(current, false)
	current.paused = true
	current.pushSince = nil
	current.probe = nil
	local climb = current.climb
	if climb then
		climb.align:Destroy()
		current.climb = nil
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function frame()
	local player = localPlayer
	if not player then
		return
	end
	local now = os.clock()
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local rootInstance = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local root = if rootInstance and rootInstance:IsA("BasePart") then rootInstance else nil
	local current = session
	if current and (current.character ~= character or current.root.Parent == nil or current.humanoid.Parent == nil) then
		release()
		current = nil
	end
	if not (character and humanoid and root) then
		lastRootY = nil
		return
	end
	local lifeState = Attributes.getString(player, P.LifeState, "Lobby")
	local moveState = Attributes.getString(player, P.MoveState, "Standing")
	local inVent = VentController.IsInVent() or moveState == "VentCrawling" or moveState == "VentScurrying"
	local position = root.Position
	local water = WaterRules.locate(scanVolumes(), position, if current then current.volume else nil)
	local decision = SwimController.membership({
		engaged = current ~= nil,
		alive = humanoid.Health > 0 and lifeState ~= "Dead" and lifeState ~= "Spectating",
		inVent = inVent,
		inWater = water ~= nil,
		climbing = current ~= nil and current.climb ~= nil,
		locked = root.Anchored or Attributes.getString(player, P.ControlLock, "None") ~= "None",
	})
	if decision == "Release" then
		release()
		current = nil
	elseif decision == "Engage" and water then
		current = engage(character, humanoid, root, water, now)
		decision = if root.Anchored or Attributes.getString(player, P.ControlLock, "None") ~= "None"
			then "Hold"
			else "Drive"
	end
	if current then
		if water then
			current.volume = water
		end
		if decision == "Hold" then
			pause(current)
		elseif decision == "Drive" then
			drive(current, player, now)
		end
	end
	lastRootY = position.Y
	lastRootAt = now
	stepStrokes(now)
end

local function onPreSimulation(_deltaTime: number)
	xpcall(frame, function(err: any)
		log.warnThrottled("frame", 5, "swim frame failed: %s\n%s", tostring(err), debug.traceback())
	end)
end

local function onRender(deltaTime: number)
	xpcall(renderView, function(err: any)
		log.warnThrottled("view", 5, "swim view failed: %s\n%s", tostring(err), debug.traceback())
	end, math.clamp(deltaTime, 0, MAX_DT))
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function invalidate(instance: Instance)
	if instance:IsA("BasePart") then
		volumes = nil
	end
end

function SwimController.Init()
	serviceTrove:Add(function()
		release()
		hideView()
		clearBubbles()
	end)
end

function SwimController.Start()
	local player = localPlayer
	if not player then
		log.warn("no local player; swimming is not driven")
		return
	end
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.PoolWater), invalidate)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.PoolWater), invalidate)
	serviceTrove:Connect(UserInputService.JumpRequest, function()
		lastJumpAt = os.clock()
	end)
	serviceTrove:Connect(player.CharacterRemoving, function(model: Model)
		local current = session
		if current and current.character == model then
			release()
		end
	end)
	serviceTrove:Connect(RunService.PreSimulation, onPreSimulation)
	local shots = Net.Client.on("OneShot", onOneShot)
	if shots then
		serviceTrove:Add(shots)
	end
	RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value + 2, onRender)
	serviceTrove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_STEP)
	end)
end

function SwimController.OnRunStarted(_info: Types.RunInfo)
	hintedSwim = false
	climbHintAt = -math.huge
	lowAirHintAt = -math.huge
end

function SwimController.OnRunEnded()
	release()
	hideView()
	clearTelegraphs()
	clearBubbles()
	table.clear(strokeTracks)
	table.clear(trailAt)
	if panicHeld then
		panicHeld = false
		FirstPersonController.SetPanicFloor(PANIC_TOKEN, nil)
	end
end

--------------------------------------------------------------------------------
-- Beyond the contract
--------------------------------------------------------------------------------

-- True while this client is swimming (driving its body in the water or held there by the server).
function SwimController.IsSwimming(): boolean
	return session ~= nil
end

-- How far under the camera is this frame (0 = in the air, 1 = under).
function SwimController.GetUnderwater(): number
	return underwater
end

-- The water this client swims in (nil when it is not swimming).
function SwimController.GetWater(): Volume?
	local current = session
	return if current then current.volume else nil
end

-- A burst of `count` bubbles from `origin` (default: the camera's mouth), under the water around it.
function SwimController.EmitBubbles(count: number, origin: Vector3?)
	local camera = Workspace.CurrentCamera
	local from = origin
	if not from and camera then
		from = camera.CFrame.Position + camera.CFrame.LookVector * 0.6 - Vector3.new(0, 0.25, 0)
	end
	if not from then
		return
	end
	local water = WaterRules.volumeAround(scanVolumes(), from, 0.2)
	if water then
		spawnBubbles(from, water.surface, count, 0.25)
	end
end

-- Adds `speed` studs/s of upward drive for `seconds` (an escape kick toward the surface).
function SwimController.Kick(speed: number, seconds: number)
	local current = session
	if not current or not MathUtil.isFinite(speed) or not MathUtil.isFinite(seconds) then
		return
	end
	current.kickSpeed = math.max(0, speed)
	current.kickUntil = os.clock() + math.max(0, seconds)
end

return table.freeze(SwimController)
