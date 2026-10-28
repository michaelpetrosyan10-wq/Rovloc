--!strict
-- FloodedPoolService: the flooded pool (spec Level 4). The server decides who is in the water, runs the oxygen meter's
-- rate for every swimmer, validates swim movement, and owns the Creature's grab: the drag under, the struggle, every
-- way out of it and the drowning. Rules shared with the swimming client live in Shared/Util/WaterRules.
--
-- Water. At GameConfig.ServerTickHz, for every playing participant of the live run with a body: a player in a duct
-- belongs to VentNetworkService (their mode is Vent; the half-flooded duct's water is never swum); anyone else is in
-- the water when WaterRules.locate puts their root in a PoolWater volume (swimmers keep it while bobbing up to
-- StayAbove over the surface). Entering sets PlayerStateService mode "Swim" (Treading / Freestyle / Underwater from the
-- intent and stamina); a fall or jump in faster than SplashSpeed is a Splash (the noise, which feeds the splash meter
-- the Creature's grab listens to, and the cue for everyone but the swimmer, whose client plays its own). Leaving sets
-- "OnFoot" again. A swimmer only leaves upward when there is something to stand on under the root (a deck, the
-- coping, a bridge fragment): climbing out is exempted from MovementAuthority for ClimbGrace seconds from the moment
-- the root rises past ClimbStart with support under it, so the climb's last lift never reads as flying. Rising out
-- with nothing under the root is not leaving: the swimmer stays in the water and the Swim validator puts them back.
--
-- Oxygen. Each tick the meter's rate follows WaterRules.oxygenRate for the player's state (PlayerStateService writes
-- the meter only when the rate changes): drains at OxygenDrain while the head is under, OxygenDrainGrabbed while
-- grabbed, holds while a jumpscare or cutscene has the body, otherwise recovers at OxygenRegen until full. Reaching 0
-- fires PlayerStateService.OxygenDepleted, which LifeStateService turns into a Down ("Drowned").
--
-- Movement. The "Swim" MovementAuthority validator (ValidatorName) judges swimmers (swimVerdict): a root more than
-- Ceiling over the surface with nothing under it is put back at the last good in-water position. Speed, teleports and
-- walls are MovementAuthority's built-in checks against the swim WalkSpeeds.
--
-- The grab (TryGrab, registered with MonsterAIService as the PoolGrabber). The Creature lunged up under a swimmer
-- whose splashing crossed the threshold. Refused (grabCheck) unless the run is live, nobody else is held, the victim
-- is Alive, swimming, out of the ducts and under no control lock. Then: CharacterService.Lock(victim, "Drag",
-- "ServerOwned") (the server owns the body), PlayerStateService override "Grabbed", a server-made drag rig on the root
-- (AlignPosition + AlignOrientation, the Humanoid platform-standing) pulling them down and back over DragSeconds to
-- dragTarget (just in front of the Creature, HoldDepth under the surface, inside the basin) and holding them there; the
-- oxygen rate becomes OxygenDrainGrabbed after topping the meter up to GrabMinOxygen (the lungful gasped as they go
-- under: every grab leaves time to fight); PrivateCue "Struggle" {phase Start, needed, creature, drag} to the victim;
-- the thrashing (StruggleThrash looped on the victim, a Splash at the grab) for everyone and Hud.TeammateGrabbed to
-- the other participants. While held, StrugglePress {sequence} goes through WaterRules.press (sequence numbers,
-- StruggleMaxPressesPerSecond, decay); progress cues (phase Progress) go out at most every ProgressCueSeconds.
-- Ways out (release, every one of them clean: rig removed, lock and override released, cue phase End with the
-- outcome, the thrash stopped):
--   Escaped     StrugglePressesToEscape counted: the Creature recoils (MonsterAIService.Stun for RecoilSeconds).
--   Flask       a ChemicalProjectileService shatter (out of the ducts) within FlaskCloudRadius of the victim: Stun.
--   Floodlight  ReleaseGrab("Floodlight") from the Level 4 controller's emergency switch: Stun.
--   LetGo       the Creature stopped holding them (GrabbedUserId, after HoldGrace): it was stunned or sent away.
-- After any of those the victim has at least FreedMinOxygen left, enough to reach the surface. Drowning: when the
-- meter would fall to DrownFloor the drain stops there and MonsterAIService.CatchGrabbed runs the Underwater jumpscare
-- (JumpscareHandler's outcome: Down the first time, Execute after); if no catch can start, the last of the air runs
-- out and LifeStateService downs them ("Drowned"). The grab also ends without a recoil when the victim leaves, dies
-- or stops playing, their character goes, the run ends ("RunEnded") or the match leaves the run.
--
-- Signals: SwimStarted(player), SwimEnded(player), GrabStarted(player), GrabEnded(player, outcome).
-- Dev command: pool grab | free | air <0-100> (the caller).
--
-- Pure rules (tests/Specs/Pool.spec.luau): grabCheck, dragTarget, dragPosition, swimVerdict, entrySplash,
-- shatterFrees, freedOxygen. SetDependencies swaps every engine and cross-service touch point (specs drive a fake
-- clock, fake volumes, locks, casts and Creature).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local SpatialQuery = require(ReplicatedStorage.Shared.Util.SpatialQuery)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)
local WaterRules = require(ReplicatedStorage.Shared.Util.WaterRules)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local MovementAuthority = require(ServerScriptService.Services.Player.MovementAuthority)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local ChemicalProjectileService = require(ServerScriptService.Services.Mechanics.ChemicalProjectileService)

local log = Log.new("Pool")

local C = Attributes.Creature
local W = Attributes.World

type Volume = WaterRules.Volume
type Struggle = WaterRules.Struggle

export type Outcome = "Escaped" | "Flask" | "Floodlight" | "LetGo" | "Caught" | "Drowned" | "Ended"

export type GrabCheck = {
	live: boolean,
	busy: boolean, -- somebody is already held
	lifeState: Enums.LifeState,
	swimming: boolean,
	inVent: boolean,
	controlLock: Enums.ControlLock,
	hasBody: boolean,
}

-- What holds a dragged body: the rig the server put on the victim's root.
export type DragRig = {
	SetTarget: (self: DragRig, position: Vector3, facing: Vector3?) -> (),
	Destroy: (self: DragRig) -> (),
}

export type Dependencies = {
	now: () -> number,
	delay: (seconds: number, callback: () -> ()) -> thread,
	cancel: (thread: thread) -> (),
	live: () -> boolean, -- a run is live (Deploying / InRun)
	players: () -> { Player }, -- the run's playing participants in the server
	rootOf: (player: Player) -> BasePart?,
	volumes: () -> { Volume },
	inVent: (player: Player) -> boolean,
	supported: (player: Player, position: Vector3) -> boolean, -- something to stand on under the root
	lock: (player: Player, reason: Enums.ControlLock, mode: Enums.LockMode) -> (),
	unlock: (player: Player, reason: Enums.ControlLock) -> (),
	getLock: (player: Player) -> Enums.ControlLock,
	exempt: (player: Player, token: string, seconds: number) -> (),
	creatureRoot: () -> BasePart?,
	creatureHolds: (player: Player) -> boolean, -- the Creature's GrabbedUserId is this player
	stun: (seconds: number, from: Vector3) -> (),
	catchGrabbed: (player: Player) -> boolean,
	attachDrag: (player: Player, root: BasePart, from: Vector3) -> DragRig?,
	cue: (player: Player, payload: Types.PrivateCuePayload) -> (),
	notify: (player: Player, key: string, args: { string }) -> (),
	emit: (position: Vector3, kind: Enums.NoiseKind, player: Player) -> (),
	playAt: (preset: string, position: Vector3, except: Player?) -> (),
	playOn: (preset: string, attach: Instance) -> AudioService.CueHandle?,
	playFor: (player: Player, preset: string) -> (),
}

type Swimmer = {
	player: Player,
	character: Model?,
	volume: Volume,
	enteredAt: number,
	lastGood: Vector3,
}

type Sample = { y: number, at: number }

type Grab = {
	player: Player,
	character: Model?,
	startedAt: number,
	from: Vector3,
	to: Vector3,
	facing: Vector3,
	volume: Volume,
	struggle: Struggle,
	rig: DragRig?,
	drownTimer: thread?,
	thrash: AudioService.CueHandle?,
	lastCueAt: number,
	cuedProgress: number,
	heldSince: number?,
	devHold: boolean, -- a dev grab: no Creature holds it
	released: boolean,
}

local TICK = 1 / GameConfig.ServerTickHz
local VALIDATOR_NAME = "Swim"
local SWIM_MODE: PlayerStateService.Mode = "Swim"
local FOOT_MODE: PlayerStateService.Mode = "OnFoot"
local GRAB_TOKEN = "Pool"
local GRABBED: Enums.MoveState = "Grabbed"
local DRAG_LOCK: Enums.ControlLock = "Drag"
local DRAG_MODE: Enums.LockMode = "ServerOwned"
local CUE_KIND: Enums.CueKind = "Struggle"
local SPLASH_NOISE: Enums.NoiseKind = "Splash"
local CLIMB_TOKEN = "PoolClimb"

local CEILING = WaterRules.StayAbove + 0.6 -- studs over the surface an unsupported swimmer's root may reach
local CLIMB_START = 0.9 -- a supported root this far over the surface is climbing out
local CLIMB_GRACE = 1.5 -- seconds of MovementAuthority exemption for the climb
local SUPPORT_REACH = 4.6 -- studs under the root a deck still counts as under it (a standing root is ~3 up)
local SPLASH_SPEED = 9 -- studs/s of fall that make an entry a splash
local SAMPLE_STALE = 0.5 -- a fall sample older than this does not count
local DRAG_SECONDS = 1.2
local HOLD_DEPTH = 4.5 -- studs under the surface the victim is held
local HOLD_SPACING = 2.4 -- studs between the victim and the Creature's root, horizontally
local HOLD_BACK = 3 -- studs back the drag pulls when there is no Creature to pull toward
local HOLD_FLOOR_CLEARANCE = 1.6 -- studs the held root stays over the volume's floor
local HOLD_WALL_CLEARANCE = 1.5 -- studs the held root stays inside the volume's sides
local HOLD_SWAY = 0.25 -- studs the held body is shaken about
local HOLD_GRACE = 1 -- seconds the Creature may not read as holding before the grab counts as let go
local GRAB_MIN_SECONDS = 4.5 -- every grab starts with at least this many seconds of air
local GRAB_MIN_OXYGEN = GameConfig.OxygenDrainGrabbed * GRAB_MIN_SECONDS
local FREED_MIN_SECONDS = 2.5 -- a freed swimmer has at least this long to reach the surface
local FREED_MIN_OXYGEN = GameConfig.OxygenDrain * FREED_MIN_SECONDS
local DROWN_FLOOR = 0.5 -- the drain stops here while the drowning catch is tried
local RECOIL_SECONDS = 3.5 -- the Creature reels back from a victim who fought free
local PROGRESS_CUE_SECONDS = 0.2
local GRAB_SPLASH_VOLUME = 1.3
local THRASH_PRESET = "StruggleThrash"
local SPLASH_PRESET = "Splash"
local STING_PRESET = "JumpscareSting"
local TEAMMATE_KEY = "Hud.TeammateGrabbed"
local FREED_OUTCOMES: { [string]: boolean } = { Escaped = true, Flask = true, Floodlight = true, LetGo = true }
local RECOIL: { [string]: number } = {
	Escaped = RECOIL_SECONDS,
	Flask = GameConfig.StunSeconds,
	Floodlight = GameConfig.StunSeconds,
}
local LIVE_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }
local HELD_LOCKS: { [string]: boolean } = { Jumpscare = true, Cutscene = true }

local FloodedPoolService = {}

FloodedPoolService.Name = "FloodedPoolService"
FloodedPoolService.ValidatorName = VALIDATOR_NAME
FloodedPoolService.GrabToken = GRAB_TOKEN
FloodedPoolService.ClimbToken = CLIMB_TOKEN
FloodedPoolService.Ceiling = CEILING
FloodedPoolService.ClimbStart = CLIMB_START
FloodedPoolService.ClimbGrace = CLIMB_GRACE
FloodedPoolService.SplashSpeed = SPLASH_SPEED
FloodedPoolService.DragSeconds = DRAG_SECONDS
FloodedPoolService.HoldDepth = HOLD_DEPTH
FloodedPoolService.HoldGrace = HOLD_GRACE
FloodedPoolService.GrabMinOxygen = GRAB_MIN_OXYGEN
FloodedPoolService.FreedMinOxygen = FREED_MIN_OXYGEN
FloodedPoolService.DrownFloor = DROWN_FLOOR
FloodedPoolService.RecoilSeconds = RECOIL_SECONDS
FloodedPoolService.ProgressCueSeconds = PROGRESS_CUE_SECONDS
FloodedPoolService.TeammateKey = TEAMMATE_KEY

local swimStarted: Signal.Signal<Player> = Signal.new()
local swimEnded: Signal.Signal<Player> = Signal.new()
local grabStarted: Signal.Signal<Player> = Signal.new()
local grabEnded: Signal.Signal<Player, Outcome> = Signal.new()

FloodedPoolService.SwimStarted = swimStarted
FloodedPoolService.SwimEnded = swimEnded
FloodedPoolService.GrabStarted = grabStarted
FloodedPoolService.GrabEnded = grabEnded

local serviceTrove = Trove.new()
local swimmers: { [Player]: Swimmer } = {}
local samples: { [Player]: Sample } = {}
local grab: Grab? = nil
local nextPollAt = -math.huge
local initialized = false
local volumeCache: { Volume }? = nil

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Pool.spec.luau)
--------------------------------------------------------------------------------

-- Whether the Creature may take this swimmer now, and why not.
function FloodedPoolService.grabCheck(check: GrabCheck): (boolean, string?)
	if not check.live then
		return false, "NoRun"
	end
	if check.busy then
		return false, "Busy"
	end
	if check.lifeState ~= "Alive" then
		return false, "LifeState"
	end
	if not check.hasBody then
		return false, "NoBody"
	end
	if check.inVent then
		return false, "InVent"
	end
	if not check.swimming then
		return false, "NotSwimming"
	end
	if check.controlLock ~= "None" then
		return false, "Locked"
	end
	return true, nil
end

-- Where a victim grabbed at `from` is dragged: down to HoldDepth under the surface and back toward the Creature's
-- root (HoldSpacing short of it; HoldBack straight back against `facing` without one), kept HoldWallClearance inside
-- the volume's sides and HoldFloorClearance over its floor.
function FloodedPoolService.dragTarget(from: Vector3, creature: Vector3?, volume: Volume, facing: Vector3): Vector3
	local flatFacing = MathUtil.flat(facing)
	local back = if flatFacing.Magnitude > 1e-3 then -flatFacing.Unit else Vector3.new(0, 0, 1)
	local horizontal: Vector3
	if creature then
		local toVictim = MathUtil.flat(from - creature)
		local away = if toVictim.Magnitude > 1e-3 then toVictim.Unit else -back
		horizontal = Vector3.new(creature.X, 0, creature.Z) + away * HOLD_SPACING
	else
		horizontal = Vector3.new(from.X, 0, from.Z) + back * HOLD_BACK
	end
	local localPoint =
		volume.cframe:PointToObjectSpace(Vector3.new(horizontal.X, volume.cframe.Position.Y, horizontal.Z))
	local halfX = math.max(0, volume.size.X / 2 - HOLD_WALL_CLEARANCE)
	local halfZ = math.max(0, volume.size.Z / 2 - HOLD_WALL_CLEARANCE)
	local clamped = volume.cframe:PointToWorldSpace(
		Vector3.new(math.clamp(localPoint.X, -halfX, halfX), 0, math.clamp(localPoint.Z, -halfZ, halfZ))
	)
	local lowest = volume.bottom + HOLD_FLOOR_CLEARANCE
	local y = math.max(lowest, math.min(volume.surface - HOLD_DEPTH, from.Y - 1))
	return Vector3.new(clamped.X, y, clamped.Z)
end

-- The victim's root `alpha` (0..1) of the way along the drag from `from` to `to`: down first (the legs go), then back.
function FloodedPoolService.dragPosition(from: Vector3, to: Vector3, alpha: number): Vector3
	local a = MathUtil.clamp01(alpha)
	local down = MathUtil.smoothstep(0, 0.7, a)
	local back = MathUtil.smoothstep(0.15, 1, a)
	return Vector3.new(
		from.X + (to.X - from.X) * back,
		from.Y + (to.Y - from.Y) * down,
		from.Z + (to.Z - from.Z) * back
	)
end

-- The Swim validator's verdict for a swimmer's root at `position` over water at `surface`: put back at `lastGood`
-- (else straight down at the surface) when it is over Ceiling with nothing under it.
function FloodedPoolService.swimVerdict(
	position: Vector3,
	surface: number,
	supported: boolean,
	lastGood: Vector3?
): (Types.MovementVerdict, Vector3?)
	if not MathUtil.isFiniteVector(position) then
		return "Strike", lastGood
	end
	if position.Y - surface <= CEILING or supported then
		return "Ok", nil
	end
	local fallback = Vector3.new(position.X, surface - 0.3, position.Z)
	local target = lastGood or fallback
	return "Correct", Vector3.new(target.X, math.min(target.Y, surface), target.Z)
end

-- Whether entering the water falling at `fallSpeed` studs/s (positive = down) is a splash.
function FloodedPoolService.entrySplash(fallSpeed: number): boolean
	return fallSpeed >= SPLASH_SPEED
end

-- Whether a flask shattering at `point` (`inVent`: inside a duct) frees a victim whose root is at `victim`.
function FloodedPoolService.shatterFrees(point: Vector3, inVent: boolean, victim: Vector3): boolean
	return not inVent and (point - victim).Magnitude <= GameConfig.FlaskCloudRadius
end

-- The oxygen to top a freed victim up to (nil: they already have enough).
function FloodedPoolService.freedOxygen(oxygen: number): number?
	return if oxygen < FREED_MIN_OXYGEN then FREED_MIN_OXYGEN else nil
end

--------------------------------------------------------------------------------
-- Live dependencies
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
	local cached = volumeCache
	if cached then
		return cached
	end
	local out: { Volume } = {}
	local ducts: { [string]: { [string]: boolean } } = {}
	local school = Instances.school()
	for _, instance in CollectionService:GetTagged(Tags.PoolWater) do
		if not instance:IsA("BasePart") or not (school and instance:IsDescendantOf(school)) then
			continue
		end
		local levelId = Attributes.getString(instance, W.LevelId, "")
		local rooms = ducts[levelId]
		if not rooms then
			rooms = ductRooms(levelId)
			ducts[levelId] = rooms
		end
		local zone = Attributes.getString(instance, W.ZoneId, "")
		local id = Attributes.getString(instance, W.TriggerId, instance.Name)
		table.insert(out, WaterRules.volumeOf(id, instance.CFrame, instance.Size, rooms[zone] == true, instance))
	end
	table.sort(out, function(a: Volume, b: Volume): boolean
		return a.id < b.id
	end)
	volumeCache = out
	return out
end

local function runParticipants(): { Player }
	local run = RunLifecycleService.GetRun()
	local out: { Player } = {}
	if not run then
		return out
	end
	for _, player in run.participants do
		if player.Parent == Players and LifeStateService.IsPlaying(player) then
			table.insert(out, player)
		end
	end
	return out
end

local function supportedBelow(player: Player, position: Vector3): boolean
	local exclude: { Instance } = {}
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if character then
			table.insert(exclude, character)
		end
	end
	local creature = Instances.creature()
	if creature then
		table.insert(exclude, creature)
	end
	local character = player.Character
	if character and table.find(exclude, character) == nil then
		table.insert(exclude, character)
	end
	local hit = Workspace:Raycast(position, Vector3.new(0, -SUPPORT_REACH, 0), SpatialQuery.worldParams(exclude))
	return hit ~= nil and hit.Normal.Y > 0.6
end

local function realDrag(player: Player, root: BasePart, from: Vector3): DragRig?
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local attachment = Instance.new("Attachment")
	attachment.Name = "PoolDrag"
	attachment.Parent = root
	local align = Instance.new("AlignPosition")
	align.Name = "PoolDrag"
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.Responsiveness = 45
	align.MaxForce = 1e7
	align.MaxVelocity = 40
	align.ApplyAtCenterOfMass = true
	align.Position = from
	align.Parent = root
	local orient = Instance.new("AlignOrientation")
	orient.Name = "PoolDrag"
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.AlignType = Enum.AlignType.AllAxes
	orient.Attachment0 = attachment
	orient.RigidityEnabled = false
	orient.Responsiveness = 30
	orient.MaxTorque = 1e7
	orient.MaxAngularVelocity = 12
	orient.CFrame = root.CFrame.Rotation
	orient.Parent = root
	if humanoid then
		humanoid.PlatformStand = true
	end
	local rig: DragRig
	rig = {
		SetTarget = function(_self: DragRig, position: Vector3, facing: Vector3?)
			if align.Parent ~= nil then
				align.Position = position
			end
			local flat = if facing then MathUtil.flat(facing) else Vector3.zero
			if orient.Parent ~= nil and flat.Magnitude > 1e-3 then
				orient.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
			end
		end,
		Destroy = function(_self: DragRig)
			align:Destroy()
			orient:Destroy()
			attachment:Destroy()
			if humanoid and humanoid.Parent ~= nil then
				humanoid.PlatformStand = false
			end
		end,
	}
	return rig
end

local function realDependencies(): Dependencies
	return {
		now = function(): number
			return Workspace:GetServerTimeNow()
		end,
		delay = function(seconds: number, callback: () -> ()): thread
			return task.delay(seconds, callback)
		end,
		cancel = function(thread: thread)
			if coroutine.status(thread) == "suspended" then
				task.cancel(thread)
			end
		end,
		live = function(): boolean
			return RunLifecycleService.GetRun() ~= nil and LIVE_PHASES[RunLifecycleService.GetPhase()] == true
		end,
		players = runParticipants,
		rootOf = function(player: Player): BasePart?
			local root = Instances.characterRoot(player)
			local humanoid = Instances.characterHumanoid(player)
			if not root or not humanoid or humanoid.Health <= 0 or not root:IsDescendantOf(Workspace) then
				return nil
			end
			return root
		end,
		volumes = scanVolumes,
		inVent = VentNetworkService.IsInVent,
		supported = supportedBelow,
		lock = CharacterService.Lock,
		unlock = CharacterService.Unlock,
		getLock = CharacterService.GetLock,
		exempt = MovementAuthority.Exempt,
		creatureRoot = Instances.creatureRoot,
		creatureHolds = function(player: Player): boolean
			local creature = MonsterAIService.GetCreature()
			return creature ~= nil and Attributes.getNumber(creature, C.GrabbedUserId, 0) == player.UserId
		end,
		stun = MonsterAIService.Stun,
		catchGrabbed = MonsterAIService.CatchGrabbed,
		attachDrag = realDrag,
		cue = function(player: Player, payload: Types.PrivateCuePayload)
			Net.Server.fire("PrivateCue", player, payload)
		end,
		notify = function(player: Player, key: string, args: { string })
			local payload: Types.NotifyPayload = { key = key, args = args }
			Net.Server.fire("Notify", player, payload)
		end,
		emit = function(position: Vector3, kind: Enums.NoiseKind, player: Player)
			NoiseAndDirectorService.Emit(position, kind, { sourcePlayer = player })
		end,
		playAt = function(preset: string, position: Vector3, except: Player?)
			AudioService.PlayAt(preset, position, { except = except, volume = GRAB_SPLASH_VOLUME })
		end,
		playOn = function(preset: string, attach: Instance): AudioService.CueHandle?
			return AudioService.PlayOn(preset, attach)
		end,
		playFor = function(player: Player, preset: string)
			AudioService.PlayFor(player, preset)
		end,
	}
end

local deps: Dependencies = realDependencies()

--------------------------------------------------------------------------------
-- Oxygen
--------------------------------------------------------------------------------

local function applyOxygen(player: Player, rate: number)
	PlayerStateService.SetOxygenRate(player, rate)
end

local function topUpOxygen(player: Player, floor: number)
	local oxygen = PlayerStateService.GetOxygen(player)
	if oxygen < floor then
		PlayerStateService.AddOxygen(player, floor - oxygen)
	end
end

local function updateOxygen(player: Player, swimmer: Swimmer?, position: Vector3?, held: boolean, grabbed: boolean)
	local state = PlayerStateService.GetMoveState(player)
	local inWater = swimmer ~= nil
	local submerged = false
	if swimmer and position then
		submerged = WaterRules.submerged(state, position.Y, swimmer.volume.surface)
	end
	applyOxygen(
		player,
		WaterRules.oxygenRate({
			inWater = inWater,
			submerged = submerged,
			grabbed = grabbed,
			held = held,
			oxygen = PlayerStateService.GetOxygen(player),
			max = GameConfig.OxygenMax,
		})
	)
end

--------------------------------------------------------------------------------
-- Swimmers
--------------------------------------------------------------------------------

local function beginSwim(player: Player, volume: Volume, position: Vector3, now: number)
	local swimmer: Swimmer = {
		player = player,
		character = player.Character,
		volume = volume,
		enteredAt = now,
		lastGood = position,
	}
	swimmers[player] = swimmer
	if PlayerStateService.GetMode(player) == FOOT_MODE then
		PlayerStateService.SetMode(player, SWIM_MODE)
	end
	local sample = samples[player]
	if sample and now - sample.at <= SAMPLE_STALE and now > sample.at then
		local fall = (sample.y - position.Y) / (now - sample.at)
		if FloodedPoolService.entrySplash(fall) then
			local point = Vector3.new(position.X, volume.surface, position.Z)
			deps.emit(point, SPLASH_NOISE, player)
			deps.playAt(SPLASH_PRESET, point, player)
		end
	end
	log.debug("%s is swimming in %s", player.Name, volume.id)
	swimStarted:Fire(player)
end

local function endSwim(player: Player, swimmer: Swimmer, setMode: boolean)
	if swimmers[player] ~= swimmer then
		return
	end
	swimmers[player] = nil
	if setMode and player.Parent == Players and PlayerStateService.GetMode(player) == SWIM_MODE then
		PlayerStateService.SetMode(player, FOOT_MODE)
	end
	swimEnded:Fire(player)
end

--------------------------------------------------------------------------------
-- Grab
--------------------------------------------------------------------------------

local function cue(current: Grab, phase: string, extra: { [string]: Types.OneShotArg }?)
	local now = deps.now()
	local args: { [string]: Types.OneShotArg } = {
		phase = phase,
		needed = WaterRules.PressesToEscape,
		progress = WaterRules.progressAt(current.struggle, now),
		drag = DRAG_SECONDS,
	}
	for key, value in (extra or {}) :: { [string]: Types.OneShotArg } do
		args[key] = value
	end
	local payload: Types.PrivateCuePayload = { kind = CUE_KIND, startAt = now, endsAt = nil, args = args }
	if current.player.Parent == Players then
		deps.cue(current.player, payload)
	end
end

local release: (current: Grab, outcome: Outcome) -> ()

local function victimPosition(current: Grab): Vector3
	local root = deps.rootOf(current.player)
	return if root then root.CFrame.Position else current.to
end

local function drown(current: Grab)
	current.drownTimer = nil
	if grab ~= current or current.released then
		return
	end
	local player = current.player
	applyOxygen(player, 0)
	local caught = false
	if not current.devHold then
		local ok, result = pcall(deps.catchGrabbed, player)
		caught = ok and result == true
		if not ok then
			log.warnThrottled("catch", 10, "the drowning catch failed: %s", tostring(result))
		end
	end
	if caught then
		release(current, "Caught")
		return
	end
	-- No catch could start: the last of the air runs out (LifeStateService downs them, "Drowned").
	release(current, "Drowned")
	PlayerStateService.AddOxygen(player, -GameConfig.OxygenMax)
end

local function scheduleDrown(current: Grab)
	local oxygen = PlayerStateService.GetOxygen(current.player)
	local seconds = WaterRules.secondsLeft(oxygen - DROWN_FLOOR, GameConfig.OxygenDrainGrabbed)
	current.drownTimer = deps.delay(seconds, function()
		drown(current)
	end)
end

release = function(current: Grab, outcome: Outcome)
	if current.released then
		return
	end
	current.released = true
	if grab == current then
		grab = nil
	end
	local player = current.player
	local timer = current.drownTimer
	current.drownTimer = nil
	if timer then
		deps.cancel(timer)
	end
	local position = victimPosition(current)
	local rig = current.rig
	current.rig = nil
	if rig then
		xpcall(function()
			rig:Destroy()
		end, function(err: any)
			log.warn("removing the drag rig failed: %s", tostring(err))
		end)
	end
	local thrash = current.thrash
	current.thrash = nil
	if thrash then
		thrash:Stop(0.4)
	end
	deps.unlock(player, DRAG_LOCK)
	PlayerStateService.PopOverride(player, GRAB_TOKEN)
	if FREED_OUTCOMES[outcome] and player.Parent == Players then
		local floor = FloodedPoolService.freedOxygen(PlayerStateService.GetOxygen(player))
		if floor then
			topUpOxygen(player, floor)
		end
	end
	local recoil = RECOIL[outcome]
	if recoil and not current.devHold then
		xpcall(deps.stun, function(err: any)
			log.warnThrottled("recoil", 10, "the recoil stun failed: %s", tostring(err))
		end, recoil, position)
	end
	if outcome == "Escaped" then
		deps.playAt(SPLASH_PRESET, position, nil)
	end
	local ending: { [string]: Types.OneShotArg } = { outcome = outcome }
	cue(current, "End", ending)
	log.info("%s's grab ended: %s", player.Name, outcome)
	grabEnded:Fire(player, outcome)
end

local function startGrab(player: Player, devHold: boolean): boolean
	local root = deps.rootOf(player)
	local swimmer: Swimmer? = swimmers[player]
	local ok, reason = FloodedPoolService.grabCheck({
		live = deps.live(),
		busy = grab ~= nil,
		lifeState = LifeStateService.GetState(player),
		swimming = swimmer ~= nil,
		inVent = deps.inVent(player),
		controlLock = deps.getLock(player),
		hasBody = root ~= nil,
	})
	if not ok or not root or not swimmer then
		log.debug("grab of %s refused: %s", player.Name, tostring(reason))
		return false
	end
	local now = deps.now()
	local from = root.CFrame.Position
	local creature = deps.creatureRoot()
	local creaturePosition = if creature then creature.CFrame.Position else nil
	local facing = root.CFrame.LookVector
	local to = FloodedPoolService.dragTarget(from, creaturePosition, swimmer.volume, facing)
	local towardCreature = if creaturePosition then MathUtil.flat(creaturePosition - to) else MathUtil.flat(facing)
	deps.lock(player, DRAG_LOCK, DRAG_MODE)
	PlayerStateService.PushOverride(player, GRAB_TOKEN, GRABBED)
	topUpOxygen(player, GRAB_MIN_OXYGEN)
	applyOxygen(player, -GameConfig.OxygenDrainGrabbed)
	local rigOk, rig = pcall(deps.attachDrag, player, root, from)
	if not rigOk then
		log.warn("attaching the drag rig to %s failed: %s", player.Name, tostring(rig))
	end
	local current: Grab = {
		player = player,
		character = player.Character,
		startedAt = now,
		from = from,
		to = to,
		facing = if towardCreature.Magnitude > 1e-3 then towardCreature.Unit else Vector3.new(0, 0, -1),
		volume = swimmer.volume,
		struggle = WaterRules.newStruggle(now),
		rig = if rigOk then rig else nil,
		drownTimer = nil,
		thrash = deps.playOn(THRASH_PRESET, root),
		lastCueAt = now,
		cuedProgress = 0,
		heldSince = nil,
		devHold = devHold,
		released = false,
	}
	grab = current
	scheduleDrown(current)
	deps.playAt(SPLASH_PRESET, Vector3.new(from.X, swimmer.volume.surface, from.Z), nil)
	deps.playFor(player, STING_PRESET)
	local opening: { [string]: Types.OneShotArg } = { creature = creaturePosition or to }
	cue(current, "Start", opening)
	local name = player.DisplayName
	for _, other in deps.players() do
		if other ~= player then
			deps.notify(other, TEAMMATE_KEY, { name })
		end
	end
	log.info("%s was grabbed", player.Name)
	grabStarted:Fire(player)
	return true
end

local function stepGrab(current: Grab, now: number)
	local rig = current.rig
	if not rig then
		return
	end
	local alpha = (now - current.startedAt) / DRAG_SECONDS
	local target = FloodedPoolService.dragPosition(current.from, current.to, alpha)
	if alpha >= 1 then
		local t = now - current.startedAt
		target += Vector3.new(
			HOLD_SWAY * math.noise(t * 1.7, 3.1),
			HOLD_SWAY * 0.6 * math.noise(t * 2.3, 7.3),
			HOLD_SWAY * math.noise(t * 1.9, 11.7)
		)
	end
	rig:SetTarget(target, current.facing)
end

local function checkGrab(current: Grab, now: number)
	local player = current.player
	if player.Parent ~= Players then
		release(current, "Ended")
		return
	end
	if player.Character ~= current.character or deps.rootOf(player) == nil then
		release(current, "Ended")
		return
	end
	if LifeStateService.GetState(player) ~= "Alive" or not deps.live() then
		release(current, "Ended")
		return
	end
	if current.devHold then
		return
	end
	if deps.creatureHolds(player) then
		current.heldSince = nil
	else
		local since = current.heldSince or now
		current.heldSince = since
		if now - since >= HOLD_GRACE and now - current.startedAt >= HOLD_GRACE then
			release(current, "LetGo")
		end
	end
end

local function sendProgress(current: Grab, now: number)
	if now - current.lastCueAt < PROGRESS_CUE_SECONDS then
		return
	end
	local progress = WaterRules.progressAt(current.struggle, now)
	if math.abs(progress - current.cuedProgress) < 0.5 then
		return
	end
	current.lastCueAt = now
	current.cuedProgress = progress
	cue(current, "Progress", nil)
end

--------------------------------------------------------------------------------
-- Poll
--------------------------------------------------------------------------------

local function pollPlayer(player: Player, volumes: { Volume }, now: number, seen: { [Player]: boolean })
	seen[player] = true
	local swimmer: Swimmer? = swimmers[player]
	local root = deps.rootOf(player)
	if not root then
		if swimmer then
			endSwim(player, swimmer, true)
		end
		samples[player] = nil
		return
	end
	if swimmer and player.Character ~= swimmer.character then
		endSwim(player, swimmer, true)
		swimmer = nil
	end
	local position = root.CFrame.Position
	if deps.inVent(player) then
		-- The ducts own this body (mode Vent); its half-flooded water is crawled, never swum.
		if swimmer then
			endSwim(player, swimmer, false)
		end
		samples[player] = { y = position.Y, at = now }
		updateOxygen(player, nil, nil, false, false)
		return
	end
	local current = grab
	local grabbed = current ~= nil and current.player == player
	local lock = deps.getLock(player)
	if lock ~= "None" and not grabbed then
		-- Someone else holds the body (a jumpscare, a cutscene): it stays where it is, and so does the meter.
		samples[player] = nil
		updateOxygen(player, swimmer, position, HELD_LOCKS[lock] == true, false)
		return
	end
	if grabbed then
		updateOxygen(player, swimmer, position, false, true)
		return
	end
	local volume = WaterRules.locate(volumes, position, if swimmer then swimmer.volume else nil)
	if swimmer and volume == nil then
		local over = WaterRules.overFootprint(swimmer.volume, position)
			and position.Y > swimmer.volume.surface + WaterRules.StayAbove
		if over and not deps.supported(player, position) then
			-- Up out of the water with nothing to stand on: not leaving (the Swim validator puts them back).
			volume = swimmer.volume
		end
	end
	if volume and not swimmer then
		beginSwim(player, volume, position, now)
		swimmer = swimmers[player]
	elseif swimmer and volume == nil then
		if deps.supported(player, position) then
			deps.exempt(player, CLIMB_TOKEN, CLIMB_GRACE)
		end
		endSwim(player, swimmer, true)
		swimmer = nil
	elseif swimmer and volume then
		swimmer.volume = volume
		if position.Y > volume.surface + CLIMB_START and deps.supported(player, position) then
			deps.exempt(player, CLIMB_TOKEN, CLIMB_GRACE)
		end
	end
	samples[player] = { y = position.Y, at = now }
	updateOxygen(player, swimmer, position, false, false)
end

-- One pass (GameConfig.ServerTickHz from Step; specs call it directly).
function FloodedPoolService.Poll(now: number?)
	local t = now or deps.now()
	if not deps.live() then
		return
	end
	local volumes = deps.volumes()
	local seen: { [Player]: boolean } = {}
	for _, player in deps.players() do
		pollPlayer(player, volumes, t, seen)
	end
	for player, swimmer in table.clone(swimmers) do
		if not seen[player] then
			endSwim(player, swimmer, true)
		end
	end
	for player in table.clone(samples) do
		if not seen[player] then
			samples[player] = nil
		end
	end
	local current = grab
	if current then
		checkGrab(current, t)
	end
end

-- One frame (every Heartbeat; specs pass a fake time): the drag rig every frame, the poll and the struggle cues at
-- the server tick.
function FloodedPoolService.Step(now: number?)
	local t = now or deps.now()
	local current = grab
	if current then
		stepGrab(current, t)
	end
	if t >= nextPollAt then
		nextPollAt = t + TICK
		FloodedPoolService.Poll(t)
		local after = grab
		if after then
			sendProgress(after, t)
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- The PoolGrabber hook (MonsterAIService.RegisterPoolGrabber): true when the grab started.
function FloodedPoolService.TryGrab(player: Player): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	return startGrab(player, false)
end

-- Applies a StrugglePress from `player` (the Net handler's body). Returns how it counted (nil: nobody is held).
function FloodedPoolService.SubmitPress(player: Player, sequence: number): WaterRules.PressVerdict?
	local current = grab
	if not current or current.player ~= player or current.released then
		return nil
	end
	if type(sequence) ~= "number" or sequence ~= sequence then
		return nil
	end
	local now = deps.now()
	local verdict: WaterRules.PressVerdict = WaterRules.press(current.struggle, sequence, now)
	if verdict == "Counted" and WaterRules.escaped(current.struggle, now) then
		release(current, "Escaped")
	end
	return verdict
end

-- Lets the held swimmer go (the floodlights, a script). False when nobody is held.
function FloodedPoolService.ReleaseGrab(outcome: Outcome): boolean
	local current = grab
	if not current then
		return false
	end
	release(current, outcome)
	return true
end

function FloodedPoolService.GetGrabbed(): Player?
	local current = grab
	return if current then current.player else nil
end

-- The held swimmer's struggle progress (0..1), 0 when nobody is held.
function FloodedPoolService.GetStruggleProgress(): number
	local current = grab
	return if current then WaterRules.progressFraction(current.struggle, deps.now()) else 0
end

function FloodedPoolService.IsSwimming(player: Player): boolean
	return swimmers[player] ~= nil
end

-- Everyone in the water right now, in UserId order.
function FloodedPoolService.Swimmers(): { Player }
	local out: { Player } = {}
	for player in swimmers do
		table.insert(out, player)
	end
	table.sort(out, function(a: Player, b: Player): boolean
		return a.UserId < b.UserId
	end)
	return out
end

-- The volume `player` swims in (nil when they are not in the water).
function FloodedPoolService.GetWater(player: Player): Volume?
	local swimmer = swimmers[player]
	return if swimmer then swimmer.volume else nil
end

-- The MovementAuthority validator (registered as ValidatorName).
function FloodedPoolService.SwimValidator(
	player: Player,
	root: BasePart,
	_dt: number
): (Types.MovementVerdict, Vector3?)
	local swimmer = swimmers[player]
	if not swimmer or swimmer.character ~= player.Character then
		return "Ok", nil
	end
	local position = root.CFrame.Position
	local surface = swimmer.volume.surface
	local supported = position.Y - surface > CEILING and deps.supported(player, position)
	local verdict: Types.MovementVerdict, target =
		FloodedPoolService.swimVerdict(position, surface, supported, swimmer.lastGood)
	if verdict == "Ok" and WaterRules.contains(swimmer.volume, position, WaterRules.StayAbove) then
		swimmer.lastGood = position
	end
	return verdict, target
end

-- Replaces the engine and cross-service touch points (specs; nil restores the real ones).
function FloodedPoolService.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
	nextPollAt = -math.huge
end

-- Forgets the cached water volumes (the school was rebuilt).
function FloodedPoolService.RefreshVolumes()
	volumeCache = nil
end

--------------------------------------------------------------------------------
-- Dev command
--------------------------------------------------------------------------------

local function poolCommand(player: Player, args: { string }): string?
	local action = string.lower(args[1] or "")
	if action == "grab" then
		if startGrab(player, true) then
			return "grabbed (dev: no Creature holds you; struggle, or 'pool free')"
		end
		return "cannot grab you now (swimming, Alive, no lock, no other grab)"
	elseif action == "free" then
		return if FloodedPoolService.ReleaseGrab("Ended") then "released" else "nobody is held"
	elseif action == "air" then
		local value = tonumber(args[2] or "")
		if not value then
			return "usage: pool air <0-100>"
		end
		local target = math.clamp(value, 0, GameConfig.OxygenMax)
		PlayerStateService.AddOxygen(player, target - PlayerStateService.GetOxygen(player))
		return string.format("oxygen %.0f", PlayerStateService.GetOxygen(player))
	end
	local held = FloodedPoolService.GetGrabbed()
	return string.format(
		"pool: %d swimming, held: %s, you %s (oxygen %.0f). usage: pool grab | free | air <0-100>",
		#FloodedPoolService.Swimmers(),
		if held then held.Name else "nobody",
		if swimmers[player] then "swimming" else "not swimming",
		PlayerStateService.GetOxygen(player)
	)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function releaseOf(player: Player, outcome: Outcome)
	local current = grab
	if current and current.player == player then
		release(current, outcome)
	end
end

local function forget(player: Player)
	releaseOf(player, "Ended")
	local swimmer = swimmers[player]
	if swimmer then
		endSwim(player, swimmer, false)
	end
	samples[player] = nil
end

function FloodedPoolService.Init()
	if initialized then
		return
	end
	initialized = true
	MonsterAIService.RegisterPoolGrabber(FloodedPoolService.TryGrab)
	MovementAuthority.RegisterValidator(VALIDATOR_NAME, FloodedPoolService.SwimValidator)
	serviceTrove:Add(
		ChemicalProjectileService.Shattered:Connect(function(point: Vector3, _thrower: Player?, inVent: boolean)
			local current = grab
			if current and FloodedPoolService.shatterFrees(point, inVent, victimPosition(current)) then
				release(current, "Flask")
			end
		end)
	)
	serviceTrove:Add(
		LifeStateService.StateChanged:Connect(function(player: Player, state: Enums.LifeState, _old: Enums.LifeState)
			if state ~= "Alive" then
				releaseOf(player, "Ended")
			end
		end)
	)
	serviceTrove:Add(CharacterService.CharacterRemoving:Connect(function(player: Player, _model: Model)
		releaseOf(player, "Ended")
	end))
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(function(phase: Enums.MatchPhase)
		if not LIVE_PHASES[phase] then
			local current = grab
			if current then
				release(current, "Ended")
			end
		end
	end))
	serviceTrove:Add(VentNetworkService.Entered:Connect(function(player: Player, _grateId: string)
		local swimmer = swimmers[player]
		if swimmer then
			endSwim(player, swimmer, false)
		end
	end))
	local function invalidate(instance: Instance)
		if instance:IsA("BasePart") then
			volumeCache = nil
		end
	end
	serviceTrove:Connect(CollectionService:GetInstanceAddedSignal(Tags.PoolWater), invalidate)
	serviceTrove:Connect(CollectionService:GetInstanceRemovedSignal(Tags.PoolWater), invalidate)
	Net.Server.on("StrugglePress", function(player: Player, payload: any)
		FloodedPoolService.SubmitPress(player, (payload :: Types.StrugglePressPayload).sequence)
	end)
	DevToolsService.Register("pool", "pool [grab|free|air <0-100>]: the flooded pool (you)", poolCommand)
end

function FloodedPoolService.Start()
	serviceTrove:Connect(RunService.Heartbeat, function()
		xpcall(FloodedPoolService.Step, function(err: any)
			log.warnThrottled("step", 10, "pool step failed: %s\n%s", tostring(err), debug.traceback())
		end, nil)
	end)
end

function FloodedPoolService.BeginRun(_ctx: Types.RunContext)
	local current = grab
	if current then
		release(current, "Ended")
	end
	table.clear(swimmers)
	table.clear(samples)
	volumeCache = nil
	nextPollAt = -math.huge
end

function FloodedPoolService.EndRun()
	local current = grab
	if current then
		release(current, "Ended")
	end
	for player, swimmer in table.clone(swimmers) do
		endSwim(player, swimmer, true)
	end
	table.clear(samples)
end

function FloodedPoolService.OnPlayerRemoving(player: Player)
	forget(player)
end

return FloodedPoolService
