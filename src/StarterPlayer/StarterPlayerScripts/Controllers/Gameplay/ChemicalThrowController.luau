--!strict
-- ChemicalThrowController: chemical flasks on this client. ChemicalProjectileService judges every pickup, throw and
-- shatter; this controller presents them.
--
-- Held flasks. Every player whose HeldItem is "ChemicalFlask" carries ChemicalFlaskBuilder.buildVisual (of their
-- HeldItemVariant) in the right hand: a client-local, cosmetic, anchored model placed every frame (PreRender) with its
-- Grip on the RightHand's grip point (HandGrip), on the local body (seen in first person) and on teammates' rigs within
-- HELD_RANGE alike. The local right hand takes HandRig's "Flask" pose (FirstPersonController.SetHandPose): carried low
-- in the right of the view, drawn back beside the head while winding up, swung through on the throw; the torch rides
-- on the chest strap meanwhile. The pose is written only while no other system needs the hands (shouldPose: not
-- Hiding, Trapped, Grabbed, Parachuting or Scripted, whose controllers own the hands then; the local flask is hidden
-- meanwhile) and is handed back as "Flashlight" once the flask is gone or the hands are taken.
--
-- Throwing (InputController "Throw", a Hold: LMB / R2 / the touch THROW button). A press winds up when canWindUp
-- allows (Alive, holding, no control lock, a MoveState that may throw, the cooldown passed, no throw awaiting the
-- server). While it is held, a dotted aim arc (ARC_DOTS Neon beads and an impact ring tinted the liquid's colour,
-- never on the Low render budget) traces the predicted flight with cosmetic raycasts. Releasing throws as soon as the
-- wind-up has lasted MIN_WINDUP (a quick tap still draws back): ItemThrow { direction = the look } goes to the server
-- and a predicted flask leaves at once from the camera eye (Ballistics.releasePoint, pulled back from walls) while
-- the hand's flask hides. The server's Launch for it is adopted: from then on the flask follows the server's parabola
-- plus the gap between the two at that moment, which shrinks to nothing over RECONCILE_SECONDS. If the hand still
-- holds the flask PREDICTION_TIMEOUT after the release, the server refused: the predicted flask goes and the hand's
-- comes back (a predicted flask that hits something before its Launch arrives waits, hidden, for the verdict). An
-- End that comes because the action went away (a context change: trapped, grabbed, a menu) cancels the throw.
--
-- Flights (ProjectileEvent). Every Launch flies along the same Ballistics parabola from its t0 (a late one fast-
-- forwards; one older than the flight's maximum is ignored), tumbling, with each frame's step cast against the world
-- (the Projectiles group, characters excluded, plus the PoolWater surfaces): the first contact plays the glass and
-- splash there at once and hides the flask. The Resolve snaps to the server: when no local shatter played, or it
-- played more than SNAP_TOLERANCE from the server's point, the glass and splash play at the server's point; the cloud
-- (and a puddle on a floor) always appears at the server's point. Expired flights just vanish.
--
-- Shatter effects (client-local, under Workspace.Cosmetic): glass shards (cosmetic parts that fly, settle where they
-- land and fade), a splash of liquid (a ParticleEmitter burst), a puddle on floors, and the cloud: a ParticleEmitter
-- with the built-in smoke texture tinted ChemicalFlaskBuilder.liquidColor and a coloured PointLight glow, for
-- GameConfig.FlaskCloudSeconds (smaller and slower inside a duct). Shard counts and emitter rates follow
-- RenderBudgetController's particleScale; the Low budget drops the glow and the aim arc.
--
-- HUD. While the local player holds a flask they may throw, the hint line says how (Hud.FlaskThrow.<Device>, for the
-- current input device).
--
-- Pure maths (tests/Specs/Chemical.spec.luau): handTarget, windupAmount, followAmount, reconcileWeight,
-- refusedAfter, shouldPose, canWindUp, hintKey, snapNeeded, cloudRate, cloudGlow, shardCount, fadeAlpha,
-- heldPivot, flightPivot.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Ballistics = require(ReplicatedStorage.Shared.Util.Ballistics)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local ChemicalFlaskBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.ChemicalFlaskBuilder)
local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)

local Controllers = script.Parent.Parent
local InputController = require(Controllers.Core.InputController)
local RenderBudgetController = require(Controllers.Core.RenderBudgetController)
local FirstPersonController = require(Controllers.FirstPerson.FirstPersonController)
local HUD = require(Controllers.HUD)

local log = Log.new("ChemicalClient")

local P = Attributes.Player

local ITEM: Enums.ItemId = "ChemicalFlask"
local THROW_ACTION: Enums.InputAction = "Throw"
local FOLDER_NAME = "Chemicals"
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local HINT_PREFIX = "Hud.FlaskThrow."

-- Throw timing (seconds)
local WINDUP_SECONDS = 0.3 -- the arm draws all the way back
local MIN_WINDUP = 0.16 -- a tap still draws back this long before letting go
local FOLLOW_SECONDS = 0.28 -- the swing through after the release
local ARC_DELAY = 0.12 -- holding this long brings the aim arc in
local ARC_FADE = 0.15
local PREDICTION_TIMEOUT = 1.2 -- still holding this long after a release: the server refused it
local RECONCILE_SECONDS = 0.25 -- a predicted flask eases onto the server's parabola over this
local SNAP_TOLERANCE = 3 -- studs between a local shatter and the server's before it is replayed there
local STALE_SECONDS = 3 -- a flight that hit something locally waits this long for its Resolve

-- Hands: frames in the eye's heading (yaw, plus PITCH_SHARE of the pitch); X right, Y up, -Z ahead.
local PITCH_SHARE = 0.7
local CARRY = CFrame.new(0.6, -0.7, -1.2) * CFrame.Angles(math.rad(8), 0, math.rad(-6))
local DRAWN = CFrame.new(0.82, 0.08, 0.05) * CFrame.Angles(math.rad(62), math.rad(-12), math.rad(-14))
local FOLLOW = CFrame.new(0.28, -0.62, -1.75) * CFrame.Angles(math.rad(-38), math.rad(10), 0)
local HAND_GRIP = CFrame.new(0, -0.12, -0.1) -- the flask's neck in the RightHand's frame (inside the fist)
local HELD_RANGE = 160 -- studs: teammates' flasks are drawn within this of the camera

-- Flight visuals
local FLASK_CENTRE = CFrame.new(0, 0.45, 0) -- the flask's middle above its foot (the flight point)
local SPIN_RATE = 9 -- rad/s tumble
local ARC_DOTS = 14
local ARC_STEP = 1 / 24
local ARC_DOT_SIZE = 0.13
local ARC_TRANSPARENCY = 0.55
local RING_DIAMETER = 1.3
local RING_THICKNESS = 0.03
local EXCLUDE_REFRESH = 0.5

-- Shatter effects
local SHARD_COUNT = 10
local SHARD_LIFE = 1.2
local SHARD_FADE = 0.45
local SHARD_GRAVITY = 70
local GLASS_COLOR = Color3.fromRGB(206, 222, 216)
local SPLASH_COUNT = 28
local SPLASH_SECONDS = 1.2
local CLOUD_RATE = 22 -- particles/s at full budget
local CLOUD_GOUT = 26 -- particles at the instant of the shatter
local CLOUD_TAIL = 2.6 -- the cloud stops emitting this long before its end, so the last puffs fade by then
local CLOUD_LIFETIME = NumberRange.new(2.2, 3.4)
local CLOUD_LIGHT_RANGE = 14
local CLOUD_LIGHT_BRIGHTNESS = 1.6
local GLOW_RISE = 0.15
local GLOW_FADE = 1.6
local PUDDLE_DIAMETER = 2.6
local PUDDLE_SPREAD = 0.45
local PUDDLE_LINGER = 3
local FLOOR_NORMAL_Y = 0.7

local HINT_KEYS: { [string]: string } = {
	KeyboardMouse = HINT_PREFIX .. "KeyboardMouse",
	Gamepad = HINT_PREFIX .. "Gamepad",
	Touch = HINT_PREFIX .. "Touch",
}

-- Everything canWindUp looks at (gathered each press; specs build it by hand).
export type WindUpCheck = {
	holding: boolean,
	lifeState: Enums.LifeState,
	moveState: Enums.MoveState,
	locked: boolean, -- a ControlLock is held
	winding: boolean, -- already winding up
	awaiting: boolean, -- a release is waiting for the server
	sinceLastThrow: number?, -- seconds since this client's last release
}

-- A cosmetic model moved as one rigid body (BulkMoveTo): each part's frame relative to the model's pivot.
type Rigid = {
	model: Model,
	parts: { BasePart },
	offsets: { CFrame },
}

type HeldVisual = {
	variant: number,
	rigid: Rigid,
}

type Projectile = {
	id: number?, -- the server's flight id (nil while only predicted)
	predicted: boolean, -- not yet adopted by a Launch
	origin: Vector3,
	velocity: Vector3,
	gravity: number,
	startAt: number, -- server time
	variant: number,
	axis: Vector3, -- tumble axis
	rigid: Rigid?,
	last: Vector3,
	offset: Vector3, -- prediction gap being eased away
	offsetAt: number?, -- os.clock() of the adoption
	impacted: boolean,
	impactPoint: Vector3?,
	impactNormal: Vector3?,
	burstPlayed: boolean,
	sentAt: number, -- os.clock() it began on this client
}

type Shard = {
	part: Part,
	position: Vector3,
	rotation: CFrame,
	velocity: Vector3,
	spin: Vector3,
	settled: boolean,
}

-- A running effect: step returns false once it is over (then its trove is cleaned).
type Effect = {
	trove: Trove.Trove,
	step: (dt: number, age: number) -> boolean,
	bornAt: number,
}

local ChemicalThrowController = {}

ChemicalThrowController.Name = "ChemicalThrowController"
ChemicalThrowController.HandGrip = HAND_GRIP
ChemicalThrowController.MinWindup = MIN_WINDUP
ChemicalThrowController.PredictionTimeout = PREDICTION_TIMEOUT
ChemicalThrowController.SnapTolerance = SNAP_TOLERANCE
ChemicalThrowController.FlaskCentre = FLASK_CENTRE
ChemicalThrowController.ReconcileSeconds = RECONCILE_SECONDS

local serviceTrove = Trove.new()
local runTrove = Trove.new()
local localPlayer: Player? = Players.LocalPlayer
local folder: Folder? = nil
local heldVisuals: { [Player]: HeldVisual } = {}
local projectiles: { Projectile } = {}
local pending: Projectile? = nil -- the local release awaiting its Launch
local effects: { Effect } = {}

-- Local throw state
local windStart: number? = nil -- os.clock() the wind-up began
local releaseQueued = false
local releasedAt: number? = nil -- os.clock() of a release the server has not answered (HeldItem unchanged)
local releaseWindup = 0
local followStart: number? = nil
local lastReleaseAt: number? = nil
local poseOwned = false
local shownHint: string? = nil

-- Aim arc
local arcDots: { BasePart } = {}
local arcRing: Part? = nil
local arcAlpha = 0
local arcShown = false

-- Casts
local castParams: RaycastParams? = nil
local castRefreshAt = -math.huge

--------------------------------------------------------------------------------
-- Pure maths (specs: tests/Specs/Chemical.spec.luau)
--------------------------------------------------------------------------------

-- The right hand's frame for the Flask pose from the eye `look`: carried (windup 0) to drawn back beside the head
-- (windup 1), then swung through (follow 0..1).
function ChemicalThrowController.handTarget(look: CFrame, windup: number, follow: number): CFrame
	local _, yaw = look:ToOrientation()
	local pitch = math.asin(math.clamp(look.LookVector.Y, -1, 1))
	local frame = CFrame.new(look.Position) * CFrame.fromOrientation(pitch * PITCH_SHARE, yaw, 0)
	local hand = CARRY:Lerp(DRAWN, MathUtil.smoothstep(0, 1, windup))
	local swing = MathUtil.smoothstep(0, 1, follow)
	if swing > 0 then
		hand = hand:Lerp(FOLLOW, swing)
	end
	return frame * hand
end

-- How far the arm has drawn back `elapsed` seconds into a wind-up (0..1).
function ChemicalThrowController.windupAmount(elapsed: number): number
	return MathUtil.clamp01(elapsed / WINDUP_SECONDS)
end

-- How far through the swing the arm is `elapsed` seconds after the release (0..1, easing out).
function ChemicalThrowController.followAmount(elapsed: number): number
	local t = MathUtil.clamp01(elapsed / FOLLOW_SECONDS)
	return 1 - (1 - t) * (1 - t)
end

-- The share of a predicted flask's gap to the server's parabola still shown `elapsed` seconds after adoption.
function ChemicalThrowController.reconcileWeight(elapsed: number): number
	return 1 - MathUtil.smoothstep(0, RECONCILE_SECONDS, elapsed)
end

-- Whether a release `elapsed` seconds ago was refused: the hand still holds the flask after PREDICTION_TIMEOUT.
function ChemicalThrowController.refusedAfter(elapsed: number, stillHolding: boolean): boolean
	return stillHolding and elapsed > PREDICTION_TIMEOUT
end

-- Whether this controller may pose the hands for the flask (another system owns them in the blocked states).
function ChemicalThrowController.shouldPose(moveState: Enums.MoveState, lifeState: Enums.LifeState): boolean
	return (lifeState == "Alive" or lifeState == "Downed") and Ballistics.mayThrowIn(moveState)
end

-- Whether a press may start a wind-up (the client's mirror of the server's throw rules).
function ChemicalThrowController.canWindUp(check: WindUpCheck): boolean
	if not check.holding or check.lifeState ~= "Alive" or check.locked or check.winding or check.awaiting then
		return false
	end
	if not Ballistics.mayThrowIn(check.moveState) then
		return false
	end
	local since = check.sinceLastThrow
	return since == nil or since >= GameConfig.FlaskThrowCooldown
end

-- The throw hint for an input device.
function ChemicalThrowController.hintKey(device: string): string
	return HINT_KEYS[device] or HINT_KEYS.KeyboardMouse
end

-- Whether the server's shatter at `serverPoint` must be replayed: nothing played locally, or too far away.
function ChemicalThrowController.snapNeeded(localPoint: Vector3?, serverPoint: Vector3): boolean
	return localPoint == nil or (localPoint - serverPoint).Magnitude > SNAP_TOLERANCE
end

-- The cloud's emission rate (particles/s) `age` seconds into a cloud lasting `seconds`, at budget `scale`.
function ChemicalThrowController.cloudRate(age: number, seconds: number, scale: number, inVent: boolean): number
	local stopAt = math.max(seconds - CLOUD_TAIL, 0)
	if age < 0 or age >= stopAt then
		return 0
	end
	local remaining = 1 - age / math.max(stopAt, 1e-3)
	local rate = CLOUD_RATE * math.max(scale, 0) * (0.35 + 0.65 * remaining)
	return if inVent then rate * 0.6 else rate
end

-- The cloud glow 0..1 `age` seconds into a cloud lasting `seconds`: up at once, out over its last GLOW_FADE.
function ChemicalThrowController.cloudGlow(age: number, seconds: number): number
	if age < 0 or age >= seconds then
		return 0
	end
	local rise = MathUtil.clamp01(age / GLOW_RISE)
	local fall = MathUtil.clamp01((seconds - age) / GLOW_FADE)
	return math.min(rise, fall)
end

-- How many glass shards a shatter throws at budget `scale`.
function ChemicalThrowController.shardCount(scale: number): number
	return math.max(3, math.round(SHARD_COUNT * math.clamp(scale, 0, 1)))
end

-- Opacity 0..1 of something `age` seconds into a `life`, fading over its last `fade` seconds.
function ChemicalThrowController.fadeAlpha(age: number, life: number, fade: number): number
	if age >= life then
		return 0
	end
	return MathUtil.clamp01((life - age) / math.max(fade, 1e-3))
end

-- Where a held flask's model pivot (its foot) goes so its Grip sits in a hand at `hand`.
function ChemicalThrowController.heldPivot(hand: CFrame): CFrame
	return hand * HAND_GRIP * ChemicalFlaskBuilder.GripOffset:Inverse()
end

-- Where a flying flask's model pivot goes for a flight point `position`, `t` seconds in, tumbling about `axis`.
function ChemicalThrowController.flightPivot(position: Vector3, axis: Vector3, t: number): CFrame
	local unit = if axis.Magnitude > 1e-6 then axis.Unit else Vector3.xAxis
	return CFrame.new(position) * CFrame.fromAxisAngle(unit, SPIN_RATE * t) * FLASK_CENTRE:Inverse()
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function chemicalsFolder(): Folder
	local existing = folder
	if existing and existing.Parent ~= nil then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = Instances.cosmetic()
	folder = created
	return created
end

local function budget(): RenderBudgetController.Budget
	return RenderBudgetController.GetBudget()
end

local function heldItemOf(player: Player): string
	return Attributes.getString(player, P.HeldItem, "None")
end

local function variantOf(player: Player): number
	return Attributes.getNumber(player, P.HeldItemVariant, 0)
end

local function myLifeState(): Enums.LifeState
	local player = localPlayer
	if not player then
		return "Lobby"
	end
	local state = player:GetAttribute(P.LifeState)
	if type(state) == "string" and Enums.has(Enums.LifeState, state) then
		return state :: Enums.LifeState
	end
	return "Lobby"
end

local function myLocked(): boolean
	local player = localPlayer
	return player ~= nil and Attributes.getString(player, P.ControlLock, "None") ~= "None"
end

-- The local hand holds a flask (the replicated item, unless a release is waiting for the server's answer).
local function localHolding(): boolean
	local player = localPlayer
	return player ~= nil and heldItemOf(player) == ITEM and releasedAt == nil
end

local function cosmeticPart(name: string, size: Vector3, material: Enum.Material, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Material = material
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	Geometry.makeCosmetic(part)
	return part
end

local function rigidOf(model: Model, pivot: CFrame): Rigid
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
			table.insert(offsets, pivot:ToObjectSpace(descendant.CFrame))
		end
	end
	return { model = model, parts = parts, offsets = offsets }
end

local function place(rigid: Rigid, pivot: CFrame)
	local frames: { CFrame } = table.create(#rigid.parts)
	for index, offset in rigid.offsets do
		frames[index] = pivot * offset
	end
	Workspace:BulkMoveTo(rigid.parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
end

local function buildFlask(variant: number): Rigid
	local model = ChemicalFlaskBuilder.buildVisual(chemicalsFolder(), CFrame.identity, variant)
	return rigidOf(model, CFrame.identity)
end

-- Raycast params for cosmetic casts: Projectiles group, every character and this controller's parts excluded
-- (refreshed every EXCLUDE_REFRESH seconds as characters come and go).
local function params(): RaycastParams
	local clock = os.clock()
	local current = castParams
	if current and clock < castRefreshAt then
		return current
	end
	local exclude: { Instance } = { chemicalsFolder() }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(exclude, character)
		end
	end
	local fresh = SpatialQuery.projectileParams(exclude)
	castParams = fresh
	castRefreshAt = clock + EXCLUDE_REFRESH
	return fresh
end

-- The first contact on from -> to: the world, and with `water` the pool's surfaces too.
local function localCast(from: Vector3, to: Vector3, water: boolean): Ballistics.Hit?
	local delta = to - from
	local length = delta.Magnitude
	if length < 1e-4 or not MathUtil.isFiniteVector(delta) then
		return nil
	end
	local best: Ballistics.Hit? = nil
	local result = Workspace:Raycast(from, delta, params())
	if result then
		local creature = Instances.creature()
		best = {
			position = result.Position,
			normal = result.Normal,
			fraction = math.clamp((result.Position - from).Magnitude / length, 0, 1),
			kind = if creature and result.Instance:IsDescendantOf(creature) then "Creature" else "World",
			instance = result.Instance,
		}
	end
	if water then
		for _, volume in CollectionService:GetTagged(Tags.PoolWater) do
			if not volume:IsA("BasePart") then
				continue
			end
			local fraction = Ballistics.surfaceCrossing(volume.CFrame, volume.Size, from, to)
			local current = best
			if fraction ~= nil and (current == nil or fraction < current.fraction) then
				local up = volume.CFrame.UpVector
				best = {
					position = from + delta * fraction,
					normal = if delta:Dot(up) > 0 then -up else up,
					fraction = fraction,
					kind = "Water",
					instance = volume :: Instance,
				}
			end
		end
	end
	return best
end

local function flightCast(from: Vector3, to: Vector3): Ballistics.Hit?
	return localCast(from, to, true)
end

local function rightHand(player: Player): BasePart?
	local character = player.Character
	local hand = if character then character:FindFirstChild("RightHand") else nil
	return if hand and hand:IsA("BasePart") then hand else nil
end

local function spinAxis(seed: number): Vector3
	local random = MathUtil.seededRandom(seed, "ChemicalFlask:spin")
	return Vector3.new(random:NextNumber(-1, 1), random:NextNumber(-0.4, 0.4), random:NextNumber(-1, 1))
end

local function addEffect(trove: Trove.Trove, step: (dt: number, age: number) -> boolean)
	local effect: Effect = { trove = trove, step = step, bornAt = os.clock() }
	table.insert(effects, effect)
end

local function endEffect(effect: Effect)
	local trove: Trove.Trove = effect.trove
	trove:Destroy()
end

--------------------------------------------------------------------------------
-- Shatter effects
--------------------------------------------------------------------------------

local function tangentOf(normal: Vector3): Vector3
	local tangent = normal:Cross(Vector3.yAxis)
	if tangent.Magnitude < 1e-3 then
		tangent = normal:Cross(Vector3.xAxis)
	end
	return tangent.Unit
end

local function spawnShards(point: Vector3, normal: Vector3, liquid: Color3)
	local trove = Trove.new()
	local random = Random.new()
	local shards: { Shard } = {}
	local tangent = tangentOf(normal)
	local bitangent = normal:Cross(tangent).Unit
	local color = GLASS_COLOR:Lerp(liquid, 0.2)
	for _ = 1, ChemicalThrowController.shardCount(budget().particleScale) do
		local size =
			Vector3.new(random:NextNumber(0.05, 0.12), random:NextNumber(0.12, 0.3), random:NextNumber(0.02, 0.05))
		local part = cosmeticPart("Shard", size, Enum.Material.Glass, color)
		part.Transparency = 0.3
		part.Reflectance = 0.1
		part.Parent = chemicalsFolder()
		trove:Add(part)
		local angle = random:NextNumber(0, 2 * math.pi)
		local spread = tangent * math.cos(angle) + bitangent * math.sin(angle)
		table.insert(shards, {
			part = part,
			position = point + normal * 0.1,
			rotation = CFrame.fromAxisAngle(random:NextUnitVector(), random:NextNumber(0, math.pi)),
			velocity = normal * random:NextNumber(5, 11)
				+ spread * random:NextNumber(3, 10)
				+ Vector3.new(0, random:NextNumber(2, 6), 0),
			spin = random:NextUnitVector() * random:NextNumber(8, 20),
			settled = false,
		})
	end
	local gravity = Vector3.new(0, -SHARD_GRAVITY, 0)
	addEffect(trove, function(dt: number, age: number): boolean
		if age >= SHARD_LIFE then
			return false
		end
		local parts: { BasePart } = table.create(#shards)
		local frames: { CFrame } = table.create(#shards)
		local opacity = ChemicalThrowController.fadeAlpha(age, SHARD_LIFE, SHARD_FADE)
		for _, shard in shards do
			if not shard.settled then
				local nextPosition = shard.position + shard.velocity * dt
				local hit = localCast(shard.position, nextPosition, false)
				if hit then
					shard.settled = true
					shard.position = hit.position + hit.normal * 0.02
					shard.rotation = CFrame.lookAt(Vector3.zero, tangentOf(hit.normal), hit.normal).Rotation
				else
					shard.position = nextPosition
					shard.velocity += gravity * dt
					local turn = shard.spin * dt
					if turn.Magnitude > 1e-6 then
						shard.rotation = CFrame.fromAxisAngle(turn.Unit, turn.Magnitude) * shard.rotation
					end
				end
			end
			shard.part.Transparency = 1 - (1 - 0.3) * opacity
			table.insert(parts, shard.part)
			table.insert(frames, CFrame.new(shard.position) * shard.rotation)
		end
		Workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
		return true
	end)
end

-- A part at `point` whose Front face (-Z) looks along `normal`, to carry emitters and lights.
local function emitterHost(name: string, point: Vector3, normal: Vector3): (Part, Attachment)
	local host = cosmeticPart(name, Vector3.one * 0.2, Enum.Material.SmoothPlastic, Color3.new(0, 0, 0))
	host.Transparency = 1
	host.CFrame = CFrame.lookAt(point, point + normal, tangentOf(normal))
	host.Parent = chemicalsFolder()
	local attachment = Instance.new("Attachment")
	attachment.Parent = host
	return host, attachment
end

local function spawnSplash(point: Vector3, normal: Vector3, liquid: Color3)
	local trove = Trove.new()
	local host, attachment = emitterHost("Splash", point + normal * 0.05, normal)
	trove:Add(host)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SMOKE_TEXTURE
	emitter.Color = ColorSequence.new(liquid)
	emitter.LightEmission = 0.5
	emitter.LightInfluence = 0.4
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.35, 0.65)
	emitter.Speed = NumberRange.new(8, 16)
	emitter.SpreadAngle = Vector2.new(55, 55)
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Acceleration = Vector3.new(0, -60, 0)
	emitter.Drag = 2
	emitter.Rate = 0
	emitter.Parent = attachment
	emitter:Emit(math.max(6, math.round(SPLASH_COUNT * budget().particleScale)))
	addEffect(trove, function(_dt: number, age: number): boolean
		return age < SPLASH_SECONDS
	end)
end

local function spawnPuddle(point: Vector3, normal: Vector3, liquid: Color3)
	local trove = Trove.new()
	local part =
		cosmeticPart("Puddle", Vector3.new(0.04, 0.6, 0.6), Enum.Material.Glass, liquid:Lerp(Color3.new(), 0.35))
	part.Shape = Enum.PartType.Cylinder
	part.Transparency = 0.35
	part.Reflectance = 0.15
	part.Parent = chemicalsFolder()
	trove:Add(part)
	local frame = CFrame.fromMatrix(point + normal * 0.02, normal, tangentOf(normal))
	part.CFrame = frame
	local life = GameConfig.FlaskCloudSeconds + PUDDLE_LINGER
	addEffect(trove, function(_dt: number, age: number): boolean
		if age >= life then
			return false
		end
		local spread = MathUtil.smoothstep(0, PUDDLE_SPREAD, age)
		local diameter = MathUtil.lerp(0.6, PUDDLE_DIAMETER, spread)
		part.Size = Vector3.new(0.04, diameter, diameter)
		part.CFrame = frame
		part.Transparency = 1 - (1 - 0.35) * ChemicalThrowController.fadeAlpha(age, life, PUDDLE_LINGER)
		return true
	end)
end

local function spawnCloud(centre: Vector3, normal: Vector3, liquid: Color3, inVent: boolean)
	local trove = Trove.new()
	local host, attachment = emitterHost("Cloud", centre, normal)
	trove:Add(host)
	local scale = budget().particleScale
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SMOKE_TEXTURE
	emitter.Color = ColorSequence.new(liquid:Lerp(Color3.new(1, 1, 1), 0.15), liquid:Lerp(Color3.new(), 0.45))
	emitter.LightEmission = 0.25
	emitter.LightInfluence = 0.6
	emitter.Size = if inVent
		then NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 2.6) })
		else NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2.6),
			NumberSequenceKeypoint.new(0.4, 6),
			NumberSequenceKeypoint.new(1, 9),
		})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.12, 0.35),
		NumberSequenceKeypoint.new(0.7, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = CLOUD_LIFETIME
	emitter.Speed = if inVent then NumberRange.new(0.6, 1.6) else NumberRange.new(1, 3.2)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, if inVent then 0.2 else 0.6, 0)
	emitter.Drag = 1.5
	emitter.RotSpeed = NumberRange.new(-25, 25)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.Rate = 0
	emitter.Parent = attachment
	emitter:Emit(math.max(4, math.round(CLOUD_GOUT * scale * (if inVent then 0.5 else 1))))
	local light: PointLight? = nil
	if budget().tier ~= "Low" then
		local glow = Instance.new("PointLight")
		glow.Color = liquid
		glow.Range = if inVent then CLOUD_LIGHT_RANGE * 0.6 else CLOUD_LIGHT_RANGE
		glow.Brightness = 0
		glow.Shadows = false
		glow.Parent = attachment
		light = glow
	end
	local seconds = GameConfig.FlaskCloudSeconds
	local over = seconds + CLOUD_LIFETIME.Max
	addEffect(trove, function(_dt: number, age: number): boolean
		if age >= over then
			return false
		end
		emitter.Rate = ChemicalThrowController.cloudRate(age, seconds, budget().particleScale, inVent)
		local glow = light
		if glow then
			glow.Brightness = CLOUD_LIGHT_BRIGHTNESS * ChemicalThrowController.cloudGlow(age, seconds)
		end
		return true
	end)
end

-- Glass and splash (the moment of the shatter).
local function burst(point: Vector3, normal: Vector3, variant: number)
	local liquid = ChemicalFlaskBuilder.liquidColor(variant)
	spawnShards(point, normal, liquid)
	spawnSplash(point, normal, liquid)
end

--------------------------------------------------------------------------------
-- Flights
--------------------------------------------------------------------------------

local function dropRigid(projectile: Projectile)
	local rigid = projectile.rigid
	if rigid then
		projectile.rigid = nil
		rigid.model:Destroy()
	end
end

local function removeProjectile(projectile: Projectile)
	dropRigid(projectile)
	local index = table.find(projectiles, projectile)
	if index then
		table.remove(projectiles, index)
	end
	if pending == projectile then
		pending = nil
	end
end

local function visualPosition(projectile: Projectile, now: number): Vector3
	local t = math.clamp(now - projectile.startAt, 0, GameConfig.FlaskMaxFlightSeconds)
	local position = Ballistics.position(projectile.origin, projectile.velocity, projectile.gravity, t)
	local adoptedAt = projectile.offsetAt
	if adoptedAt then
		position += projectile.offset * ChemicalThrowController.reconcileWeight(os.clock() - adoptedAt)
	end
	return position
end

local function newProjectile(
	origin: Vector3,
	velocity: Vector3,
	gravity: number,
	startAt: number,
	variant: number,
	seed: number,
	predicted: boolean
): Projectile
	local projectile: Projectile = {
		id = nil,
		predicted = predicted,
		origin = origin,
		velocity = velocity,
		gravity = gravity,
		startAt = startAt,
		variant = variant,
		axis = spinAxis(seed),
		rigid = buildFlask(variant),
		last = origin,
		offset = Vector3.zero,
		offsetAt = nil,
		impacted = false,
		impactPoint = nil,
		impactNormal = nil,
		burstPlayed = false,
		sentAt = os.clock(),
	}
	-- A late Launch starts where the flask is now; its first step casts the stretch it skipped (from the release).
	local now = serverNow()
	local rigid = projectile.rigid
	if rigid then
		local age = math.max(now - startAt, 0)
		place(rigid, ChemicalThrowController.flightPivot(visualPosition(projectile, now), projectile.axis, age))
	end
	table.insert(projectiles, projectile)
	return projectile
end

local function findProjectile(id: number): Projectile?
	for _, projectile in projectiles do
		if projectile.id == id then
			return projectile
		end
	end
	return nil
end

-- The local prediction meets its Launch: the server's parabola from now on, the gap eased away.
local function adopt(projectile: Projectile, payload: Types.ProjectileEventPayload)
	local now = serverNow()
	local shown = visualPosition(projectile, now)
	projectile.id = payload.id
	projectile.predicted = false
	projectile.origin = payload.origin
	projectile.velocity = payload.velocity
	projectile.gravity = payload.gravity
	projectile.startAt = payload.t0
	local t = math.clamp(now - payload.t0, 0, GameConfig.FlaskMaxFlightSeconds)
	projectile.offset = shown - Ballistics.position(payload.origin, payload.velocity, payload.gravity, t)
	projectile.offsetAt = os.clock()
	local point, normal = projectile.impactPoint, projectile.impactNormal
	if projectile.impacted and not projectile.burstPlayed and point and normal then
		projectile.burstPlayed = true
		burst(point, normal, projectile.variant)
	end
end

local function onLaunch(payload: Types.ProjectileEventPayload)
	local player = localPlayer
	local mine = player ~= nil and payload.throwerUserId == player.UserId
	local waiting = pending
	if mine and waiting and waiting.id == nil then
		pending = nil
		adopt(waiting, payload)
		return
	end
	if findProjectile(payload.id) or serverNow() - payload.t0 > GameConfig.FlaskMaxFlightSeconds then
		return
	end
	local projectile =
		newProjectile(payload.origin, payload.velocity, payload.gravity, payload.t0, payload.variant, payload.id, false)
	projectile.id = payload.id
end

local function onResolve(payload: Types.ProjectileEventPayload)
	local projectile = findProjectile(payload.id)
	if projectile then
		removeProjectile(projectile)
	end
	local kind = payload.hitKind
	local point = payload.hitPosition
	if kind == nil or kind == "Expired" or point == nil then
		return
	end
	local rawNormal = payload.hitNormal
	local normal = if rawNormal and rawNormal.Magnitude > 1e-6 then rawNormal.Unit else Vector3.yAxis
	local played = if projectile and projectile.burstPlayed then projectile.impactPoint else nil
	if ChemicalThrowController.snapNeeded(played, point) then
		burst(point, normal, payload.variant)
	end
	local liquid = ChemicalFlaskBuilder.liquidColor(payload.variant)
	local inVent = payload.inVent == true
	spawnCloud(point + normal * 0.6, normal, liquid, inVent)
	if kind == "World" and not inVent and normal.Y >= FLOOR_NORMAL_Y then
		spawnPuddle(point, normal, liquid)
	end
end

local function onProjectileEvent(payload: any)
	if type(payload) ~= "table" or type(payload.id) ~= "number" then
		return
	end
	local event = payload :: Types.ProjectileEventPayload
	if typeof(event.origin) ~= "Vector3" or typeof(event.velocity) ~= "Vector3" or type(event.t0) ~= "number" then
		return
	end
	if event.phase == "Spawn" then
		onLaunch(event)
	elseif event.phase == "Resolve" then
		onResolve(event)
	end
end

local function stepProjectiles()
	local now = serverNow()
	local clock = os.clock()
	for _, projectile in table.clone(projectiles) do
		local age = now - projectile.startAt
		local stale = GameConfig.FlaskMaxFlightSeconds + STALE_SECONDS
		if age > stale or clock - projectile.sentAt > stale + STALE_SECONDS then
			removeProjectile(projectile)
			continue
		end
		if projectile.impacted then
			continue
		end
		local position = visualPosition(projectile, now)
		local hit = flightCast(projectile.last, position)
		if hit then
			projectile.impacted = true
			projectile.impactPoint = hit.position
			projectile.impactNormal = if hit.normal.Magnitude > 1e-6 then hit.normal.Unit else Vector3.yAxis
			dropRigid(projectile)
			if not projectile.predicted then
				projectile.burstPlayed = true
				burst(hit.position, projectile.impactNormal :: Vector3, projectile.variant)
			end
			continue
		end
		projectile.last = position
		local rigid = projectile.rigid
		if age >= GameConfig.FlaskMaxFlightSeconds then
			dropRigid(projectile)
		elseif rigid then
			place(rigid, ChemicalThrowController.flightPivot(position, projectile.axis, math.max(age, 0)))
		end
	end
end

--------------------------------------------------------------------------------
-- Held flasks
--------------------------------------------------------------------------------

local function dropHeld(player: Player)
	local visual = heldVisuals[player]
	if visual then
		heldVisuals[player] = nil
		visual.rigid.model:Destroy()
	end
end

local function updateHeld(cameraPosition: Vector3?)
	for player in table.clone(heldVisuals) do
		if player.Parent ~= Players then
			dropHeld(player)
		end
	end
	for _, player in Players:GetPlayers() do
		local hand = rightHand(player)
		local isLocal = player == localPlayer
		local wanted = hand ~= nil
		if isLocal then
			wanted = wanted
				and localHolding()
				and ChemicalThrowController.shouldPose(FirstPersonController.GetPredictedMoveState(), myLifeState())
		else
			wanted = wanted and heldItemOf(player) == ITEM
			if wanted and hand and cameraPosition then
				wanted = (hand.CFrame.Position - cameraPosition).Magnitude <= HELD_RANGE
			end
		end
		local visual: HeldVisual? = heldVisuals[player]
		local variant = variantOf(player)
		if not wanted or hand == nil then
			dropHeld(player)
			continue
		end
		if visual and visual.variant ~= variant then
			dropHeld(player)
			visual = nil
		end
		if not visual then
			visual = { variant = variant, rigid = buildFlask(variant) }
			heldVisuals[player] = visual
		end
		place((visual :: HeldVisual).rigid, ChemicalThrowController.heldPivot(hand.CFrame))
	end
end

--------------------------------------------------------------------------------
-- Aim arc
--------------------------------------------------------------------------------

local function arcParts(): ({ BasePart }, Part)
	if #arcDots == 0 then
		for index = 1, ARC_DOTS do
			local dot: Part =
				cosmeticPart("ArcDot" .. index, Vector3.one * ARC_DOT_SIZE, Enum.Material.Neon, Color3.new(1, 1, 1))
			dot.Shape = Enum.PartType.Ball
			dot.Transparency = 1
			dot.Parent = chemicalsFolder()
			runTrove:Add(dot)
			table.insert(arcDots, dot)
		end
	end
	local ring = arcRing
	if ring == nil or ring.Parent == nil then
		local created = cosmeticPart(
			"ArcRing",
			Vector3.new(RING_THICKNESS, RING_DIAMETER, RING_DIAMETER),
			Enum.Material.Neon,
			Color3.new(1, 1, 1)
		)
		created.Shape = Enum.PartType.Cylinder
		created.Transparency = 1
		created.Parent = chemicalsFolder()
		runTrove:Add(created)
		arcRing = created
		ring = created
	end
	return arcDots, ring :: Part
end

local function hideArc()
	arcAlpha = 0
	if not arcShown then
		return
	end
	arcShown = false
	for _, dot in arcDots do
		dot.Transparency = 1
	end
	local ring = arcRing
	if ring then
		ring.Transparency = 1
	end
end

-- Traces the throw the player would make now and lays the beads and the ring along it (never on the Low budget).
local function updateArc(dt: number, origin: Vector3, velocity: Vector3, variant: number)
	if budget().tier == "Low" then
		hideArc()
		return
	end
	arcShown = true
	arcAlpha = math.min(1, arcAlpha + dt / ARC_FADE)
	local dots, ring = arcParts()
	local hit, points =
		Ballistics.trace(origin, velocity, Ballistics.Gravity, GameConfig.FlaskMaxFlightSeconds, ARC_STEP, flightCast)
	local beads = Ballistics.resample(points, ARC_DOTS + 1)
	local color = ChemicalFlaskBuilder.liquidColor(variant)
	local transparency = 1 - (1 - ARC_TRANSPARENCY) * arcAlpha
	local frames: { CFrame } = table.create(ARC_DOTS)
	for index, dot in dots do
		local point = beads[index + 1] or beads[#beads]
		frames[index] = CFrame.new(point)
		if dot.Color ~= color then
			dot.Color = color
		end
		-- the beads thin out toward the landing
		dot.Transparency = transparency + (1 - transparency) * (index / (ARC_DOTS + 1)) * 0.5
	end
	Workspace:BulkMoveTo(dots, frames, Enum.BulkMoveMode.FireCFrameChanged)
	if hit then
		local normal = if hit.normal.Magnitude > 1e-6 then hit.normal.Unit else Vector3.yAxis
		ring.CFrame = CFrame.fromMatrix(hit.position + normal * 0.03, normal, tangentOf(normal))
		ring.Color = color
		ring.Transparency = transparency
	else
		ring.Transparency = 1
	end
end

--------------------------------------------------------------------------------
-- Throwing
--------------------------------------------------------------------------------

local function setPose(target: CFrame?)
	if target then
		FirstPersonController.SetHandPose("Flask", target)
		poseOwned = true
	elseif poseOwned then
		poseOwned = false
		FirstPersonController.SetHandPose("Flashlight")
	end
end

local function cancelWindup()
	windStart = nil
	releaseQueued = false
end

local function windUpCheck(): WindUpCheck
	local since = lastReleaseAt
	return {
		holding = localHolding(),
		lifeState = myLifeState(),
		moveState = FirstPersonController.GetPredictedMoveState(),
		locked = myLocked(),
		winding = windStart ~= nil,
		awaiting = releasedAt ~= nil,
		sinceLastThrow = if since then os.clock() - since else nil,
	}
end

-- The predicted release from the camera eye along the look: (origin, velocity).
local function predictedThrow(): (Vector3, Vector3, Vector3)
	local yaw, pitch = FirstPersonController.GetLook()
	local direction = MathUtil.vectorFromYawPitch(yaw, pitch)
	local eye = FirstPersonController.GetEyeCFrame().Position
	local release = Ballistics.releasePoint(eye, direction)
	local blocked = localCast(eye, release, false)
	local origin = Ballistics.pullBack(eye, release, if blocked then blocked.position else nil)
	local speed = Ballistics.throwSpeed(FirstPersonController.GetPredictedMoveState())
	return origin, Ballistics.launchVelocity(direction, speed), direction
end

local function release()
	local player = localPlayer
	if not player then
		cancelWindup()
		return
	end
	local origin, velocity, direction = predictedThrow()
	releaseWindup = ChemicalThrowController.windupAmount(os.clock() - (windStart or os.clock()))
	cancelWindup()
	local message: Types.ItemThrowPayload = { direction = direction }
	Net.Client.fire("ItemThrow", message)
	local clock = os.clock()
	releasedAt = clock
	lastReleaseAt = clock
	followStart = clock
	pending = newProjectile(
		origin,
		velocity,
		Ballistics.Gravity,
		serverNow(),
		variantOf(player),
		player.UserId + math.floor(clock * 1000),
		true
	)
end

local function onThrowAction(phase: InputController.Phase)
	if phase == "Begin" then
		if ChemicalThrowController.canWindUp(windUpCheck()) then
			windStart = os.clock()
			releaseQueued = false
		end
	elseif windStart ~= nil then
		if InputController.IsBound(THROW_ACTION) then
			releaseQueued = true
		else
			cancelWindup()
		end
	end
end

local function stepThrow(dt: number)
	local clock = os.clock()
	local player = localPlayer
	-- A release the server has not answered: refused once the hand still holds the flask after the timeout.
	local sent = releasedAt
	if sent and player then
		local holdingNow = heldItemOf(player) == ITEM
		if ChemicalThrowController.refusedAfter(clock - sent, holdingNow) then
			releasedAt = nil
			local waiting = pending
			if waiting and waiting.id == nil then
				removeProjectile(waiting)
			end
		elseif not holdingNow then
			releasedAt = nil
		end
	end

	local moveState: Enums.MoveState = FirstPersonController.GetPredictedMoveState()
	local lifeState: Enums.LifeState = myLifeState()
	local posing = ChemicalThrowController.shouldPose(moveState, lifeState)

	-- Wind-up: lost the right to throw on the way? Cancel. Released and drawn back far enough? Throw.
	local started = windStart
	if started then
		local check = windUpCheck()
		check.winding = false
		if not ChemicalThrowController.canWindUp(check) then
			cancelWindup()
		elseif releaseQueued and clock - started >= MIN_WINDUP then
			release()
		end
	end

	-- Hands
	local eye = FirstPersonController.GetEyeCFrame()
	local swingStart = followStart
	local swinging = swingStart ~= nil and clock - swingStart < FOLLOW_SECONDS
	if not swinging then
		followStart = nil
	end
	local handTarget: CFrame? = nil
	if posing and swinging and swingStart then
		local swing = ChemicalThrowController.followAmount(clock - swingStart)
		handTarget = ChemicalThrowController.handTarget(eye, releaseWindup, swing)
	elseif posing and localHolding() then
		local winding = windStart
		local amount = if winding then ChemicalThrowController.windupAmount(clock - winding) else 0
		handTarget = ChemicalThrowController.handTarget(eye, amount, 0)
	end
	setPose(handTarget)

	-- Aim arc
	local winding = windStart
	local showing = winding ~= nil and clock - winding >= ARC_DELAY and posing
	if showing then
		local origin, velocity = predictedThrow()
		updateArc(dt, origin, velocity, if player then variantOf(player) else 0)
	else
		hideArc()
	end

	-- Hint
	local wanted: string? = nil
	if localHolding() and lifeState == "Alive" and posing then
		wanted = ChemicalThrowController.hintKey(InputController.GetDevice())
	end
	if wanted ~= shownHint then
		local previous = shownHint
		if previous then
			HUD.ClearHint(previous)
		end
		if wanted then
			HUD.ShowHint(wanted, 0)
		end
		shownHint = wanted
	end
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function stepEffects(dt: number)
	local clock = os.clock()
	for index = #effects, 1, -1 do
		local effect = effects[index]
		local ok, alive = pcall(effect.step, dt, clock - effect.bornAt)
		if not ok then
			log.warnThrottled("effect", 10, "chemical effect failed: %s", tostring(alive))
		end
		if not ok or not alive then
			table.remove(effects, index)
			endEffect(effect)
		end
	end
end

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	stepThrow(dt)
	updateHeld(if camera then camera.CFrame.Position else nil)
	stepProjectiles()
	stepEffects(dt)
end

local function clearAll()
	cancelWindup()
	releasedAt = nil
	followStart = nil
	lastReleaseAt = nil
	setPose(nil)
	hideArc()
	local hint = shownHint
	if hint then
		HUD.ClearHint(hint)
		shownHint = nil
	end
	for player in table.clone(heldVisuals) do
		dropHeld(player)
	end
	for _, projectile in table.clone(projectiles) do
		removeProjectile(projectile)
	end
	pending = nil
	for index = #effects, 1, -1 do
		endEffect(effects[index])
	end
	table.clear(effects)
	runTrove:Clean()
	table.clear(arcDots)
	arcRing = nil
	arcAlpha = 0
	arcShown = false
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ChemicalThrowController.Init()
	serviceTrove:Add(function()
		clearAll()
	end)
end

function ChemicalThrowController.Start()
	local player = localPlayer
	if not player then
		log.warn("no local player; chemical flasks are not presented")
		return
	end
	serviceTrove:Add(InputController.Action(THROW_ACTION):Connect(onThrowAction))
	serviceTrove:Connect(player:GetAttributeChangedSignal(P.HeldItem), function()
		releasedAt = nil
	end)
	local connection = Net.Client.on("ProjectileEvent", onProjectileEvent)
	if connection then
		serviceTrove:Add(connection)
	end
	serviceTrove:Connect(RunService.PreRender, function(dt: number)
		xpcall(step, function(err: any)
			log.warnThrottled("step", 10, "chemical step failed: %s", tostring(err))
		end, math.min(dt, 0.1))
	end)
end

function ChemicalThrowController.OnRunEnded()
	clearAll()
end

return table.freeze(ChemicalThrowController)
