--!strict
-- Level1_HallwaysController: Floor 1's scripted classroom scare (spec, Level 1). Once per run.
--
-- Staging. When the level activates the Creature is taken with MonsterAIService.AcquireScripted(TOKEN). On the next
-- step (after MonsterAIService has handled the activation itself, which may have moved it to the level's spawn) it is
-- teleported to the CreatureScarePose anchor (L1_ScarePose_Classroom108, root height, facing into the north-west
-- corner of Classroom 108), PoseMode Hunched (a scripted hold in Hunched poses the Dormant corner crouch) and shown.
-- It is only ever staged while nobody can see the spot it leaves or the pose, so it never pops in front of anyone;
-- a Creature that could not be acquired (busy) is asked for again every STAGE_RETRY seconds the same way. The
-- ClassroomGlow lights over the corner burn (LightingMood keeps the scripted fixtures lit).
--
-- The trigger, at GameConfig.ServerTickHz, for the first playing participant on the level (ranked when several
-- trigger together) who:
--   Glass      stands in the ScareStep volume (L1_Trigger_GlassStep, the glass outside the ajar door),
--   Classroom  is inside Classroom 108 (in through the door, or out of its vent grate),
--   Near       is within NEAR_DISTANCE of the Creature with a clear line to its eyes (never from inside a duct),
--   Slipped    is in the corridor between the glass and the gate (round through Classroom 136, or out of a vent),
--   Beyond     is past the gate (any room joined to the exit airlock without the gate) or in the gate's bypass vent.
-- So however the squad comes (corridor, side rooms, ducts, a late arrival already standing on the glass) the scare
-- runs before anyone can reach the far side with the gate still up.
--
-- The scene (Scenes.ClassroomScare times, from startAt S = trigger + GameConfig.OneShotLead): the FloorDebris noise at
-- the subject's feet now; OneShot Timeline "L1_ClassroomScare" (subject, feet, the Creature's eyes, whether the
-- subject can see it, the two glow fixtures) for the crunch, the subject's stumble and the drag of their view onto
-- the Creature, NeckSnap, the hush and the burst sounds; just before the snap the body turns its back square to the
-- subject so the 180-degree stare lands on them; LightBurst OneShots for L1_Light_ClassroomGlow and
-- L1_Light_ClassroomGlowSpill; CreatureVanish as the bulbs stutter out and SetHidden(true) as they die; their
-- BaseBrightness set to 0 for the rest of the run (late joiners never saw the burst; restored at EndRun); the
-- HallwayGate locked shut in GATE_SECONDS so it lands at GateLand (DoorService: GateSlam, the shake, the DoorSlam
-- noise; Locked refuses every gameplay open, so the bypass vent is the only way on); the hidden Creature moved to the
-- nearest patrol spot east of the gate that is HIDE_DISTANCE from every player and out of everyone's sight; and
-- 6-9 s (seeded) after the slam Release("Patrol") + Alert(the glass, "High"): it comes hunting from out of sight.
-- Without a staged Creature the scare is skipped: the crunch and stumble alone ("L1_GlassStep") and the gate.
--
-- Deactivate cancels everything still scheduled: a scene cut short leaves the world as the scene would (gate shut,
-- bulbs dead) and the Creature is let go Dormant (the next level takes it). The run ending restores the bulbs.
--
-- Dev command: scare (play it now with you as the subject).
--
-- Pure rules (tests/Specs/Levels.spec.luau): geometry, triggerReason, pickSubject, releaseDelay, backTurn.
-- SetDependencies swaps every service the controller touches, so specs run the whole scene on a fake clock.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local CreatureRigBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.CreatureRigBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local ZoneService = require(ServerScriptService.Services.Core.ZoneService)
local VentNetworkService = require(ServerScriptService.Services.Vents.VentNetworkService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local DoorService = require(ServerScriptService.Services.Mechanics.DoorService)

local LevelKit = require(script.Parent.LevelKit)

local log = Log.new("Level1")

local P = Attributes.Player
local W = Attributes.World

type Handle = MonsterAIService.ScriptedHandle
type Schedule = LevelKit.Schedule

export type Reason = "Glass" | "Classroom" | "Near" | "Slipped" | "Beyond"

export type Geometry = {
	origin: Vector3,
	pose: CFrame, -- world: the Creature's root in the corner
	glassId: string,
	corridor: string, -- the room the glass lies in
	glassMinX: number, -- level-local X of the glass band's west edge (the squad walks east -> west)
	gateX: number, -- level-local X of the gate's wall
	classroom: string,
	beyond: { [string]: boolean }, -- rooms past the gate, plus the gate's bypass vent
	lights: { { id: string, position: Vector3 } }, -- world, burst order
	hidingSpots: { Vector3 }, -- world root positions east of the gate
	alertPoint: Vector3, -- world: the middle of the glass, on the floor
}

-- One participant as the trigger sees them.
export type Sample = {
	onGlass: boolean,
	zone: string?,
	localX: number?, -- level-local X of their root
	inVent: boolean,
	distance: number?, -- to the Creature's eyes (nil: no staged Creature)
	sightline: boolean, -- a clear line from their eyes to its eyes
}

export type Dependencies = {
	now: () -> number,
	players: () -> { Player }, -- playing participants on the level
	eyeOf: (player: Player) -> Vector3?,
	feetOf: (player: Player) -> Vector3?,
	zoneOf: (player: Player) -> string?,
	onGlass: (player: Player) -> boolean,
	inVent: (player: Player) -> boolean,
	lineClear: (from: Vector3, to: Vector3) -> boolean,
	acquire: (token: string) -> Handle?,
	alert: (position: Vector3, priority: Enums.NoisePriority) -> (),
	creatureRoot: () -> CFrame?,
	creatureModel: () -> Model?,
	creatureHidden: () -> boolean,
	gate: () -> Model?,
	lockGate: (gate: Model, seconds: number) -> boolean,
	oneShot: (kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg }, subject: Instance?) -> (),
	emit: (position: Vector3, kind: Enums.NoiseKind, source: Player?) -> (),
	fixture: (lightId: string) -> BasePart?,
}

type Scene = {
	startAt: number,
	subject: Player,
	reason: Reason,
	full: boolean,
	triggerEye: Vector3,
	gateLocked: boolean,
	lightsKilled: boolean,
	relocated: boolean,
}

local LEVEL: Enums.LevelId = "Level1_Hallways"
local TOKEN = "L1_ClassroomScare"
local POSE_ANCHOR = "L1_ScarePose_Classroom108"
local GLASS_TRIGGER = "L1_Trigger_GlassStep"
local CLASSROOM_ROOM = "L1_Classroom_108"
local BURST_LIGHTS: { string } = { "L1_Light_ClassroomGlow", "L1_Light_ClassroomGlowSpill" }
local GATE_ID = "HallwayGate"
local BYPASS_CHASE = "L1_Chase_Gate"
local SEALED_DOOR_KINDS: { [string]: boolean } = { Gate = true, Boarded = true }
local NEAR_DISTANCE = 14
local GATE_SECONDS = 0.35
local GATE_STATE: Enums.DoorState = "Locked"
local HIDE_DISTANCE = 30 -- the hidden Creature waits at least this far from every player
local EAST_MARGIN = 16 -- and at least this far east of the gate
local STAGE_RETRY = 1
local TICK = 1 / GameConfig.ServerTickHz
local LEAD = GameConfig.OneShotLead
local STAGED_POSE: Enums.PoseMode = "Hunched"
local RELEASED_POSE: Enums.PoseMode = "Biped"
local RELEASE_STATE: Enums.MonsterState = "Patrol"
local PARKED_STATE: Enums.MonsterState = "Dormant"
local ALERT_PRIORITY: Enums.NoisePriority = "High"
local CRUNCH_NOISE: Enums.NoiseKind = "FloorDebris"
local TIMELINE_KIND: Enums.OneShotKind = "Timeline"
local BURST_KIND: Enums.OneShotKind = "LightBurst"
local VANISH_KIND: Enums.OneShotKind = "CreatureVanish"
local ROOT_HEIGHT = CreatureConfig.Rig.HipHeight + CreatureConfig.Rig.RootSize.Y / 2
local STAGED_EYE = CreatureConfig.EyeHeightAboveRoot.Hunched
local STANDING_EYE = CreatureConfig.EyeHeightAboveRoot.Biped
local REASON_RANK: { [string]: number } = { Glass = 1, Classroom = 2, Near = 3, Slipped = 4, Beyond = 5 }
local CLASSROOM = Scenes.ClassroomScare
local ARGS = Scenes.Args

local Level1 = {}

Level1.LevelId = LEVEL
Level1.Token = TOKEN
Level1.NearDistance = NEAR_DISTANCE
Level1.GateSeconds = GATE_SECONDS
Level1.HideDistance = HIDE_DISTANCE
Level1.BurstLights = table.freeze(table.clone(BURST_LIGHTS))

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

local function findAnchor(layout: LayoutSchema.LevelLayout, id: string): LayoutSchema.Anchor?
	for _, anchor in layout.anchors do
		if anchor.id == id then
			return anchor
		end
	end
	return nil
end

-- Everything the scene needs from Level 1's blueprint (world positions; X / Z of the plan are level-local).
function Level1.geometry(layout: LayoutSchema.LevelLayout): Geometry
	local origin = WorldConfig.levelOrigin(layout.id)
	local rooms = LayoutSchema.indexRooms(layout)
	local poseAnchor = findAnchor(layout, POSE_ANCHOR)
	assert(poseAnchor, "Level 1 has no " .. POSE_ANCHOR)
	local glass: LayoutSchema.Trigger? = nil
	for _, trigger in layout.triggers do
		if trigger.id == GLASS_TRIGGER then
			glass = trigger
		end
	end
	assert(glass, "Level 1 has no " .. GLASS_TRIGGER)

	local gateX = glass.rect.x
	for _, door in layout.doors do
		if door.scriptedId == GATE_ID then
			local a, b = rooms[door.rooms[1]], rooms[door.rooms[2]]
			local edge = if a and b then LayoutSchema.sharedEdge(a.rect, b.rect) else nil
			if edge and edge.axis == "X" then
				gateX = edge.coord
			end
		end
	end

	-- Past the gate: every room the exit airlock reaches through doors other than the gate and the barricades.
	local beyond: { [string]: boolean } = { [layout.exit] = true }
	local frontier: { string } = { layout.exit }
	while #frontier > 0 do
		local here = table.remove(frontier) :: string
		for _, door in layout.doors do
			if SEALED_DOOR_KINDS[door.kind] then
				continue
			end
			local a, b = door.rooms[1], door.rooms[2]
			local other = if a == here then b elseif b == here then a else nil
			if other and not beyond[other] then
				beyond[other] = true
				table.insert(frontier, other)
			end
		end
	end
	if rooms[BYPASS_CHASE] then
		beyond[BYPASS_CHASE] = true
	end

	local lights: { { id: string, position: Vector3 } } = {}
	for _, id in BURST_LIGHTS do
		for _, room in layout.rooms do
			for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
				if light.id == id then
					table.insert(lights, { id = id, position = origin + light.pos })
				end
			end
		end
	end

	local hidingSpots: { Vector3 } = {}
	for _, anchor in layout.anchors do
		if anchor.kind == "PatrolWaypoint" and anchor.pos.X > gateX + EAST_MARGIN then
			table.insert(hidingSpots, origin + Vector3.new(anchor.pos.X, anchor.pos.Y + ROOT_HEIGHT, anchor.pos.Z))
		end
	end

	local centre = LayoutSchema.rectCenter(glass.rect)
	return {
		origin = origin,
		pose = Builder.anchorCFrame(layout.id, poseAnchor),
		glassId = glass.id,
		corridor = glass.room,
		glassMinX = glass.rect.x,
		gateX = gateX,
		classroom = CLASSROOM_ROOM,
		beyond = beyond,
		lights = lights,
		hidingSpots = hidingSpots,
		alertPoint = origin + Vector3.new(centre.X, 0, centre.Y),
	}
end

-- Why `sample` sets the scare off (nil: it does not).
function Level1.triggerReason(sample: Sample, geometry: Geometry): Reason?
	if sample.onGlass then
		return "Glass"
	end
	local zone = sample.zone
	if zone == geometry.classroom then
		return "Classroom"
	end
	local distance = sample.distance
	if not sample.inVent and distance ~= nil and distance <= NEAR_DISTANCE and sample.sightline then
		return "Near"
	end
	local x = sample.localX
	if zone == geometry.corridor and x ~= nil and x < geometry.glassMinX then
		return "Slipped"
	end
	if zone ~= nil and geometry.beyond[zone] then
		return "Beyond"
	end
	return nil
end

-- The subject among simultaneous triggers: the most direct reason, then list order.
function Level1.pickSubject<T>(candidates: { { who: T, reason: Reason } }): (T?, Reason?)
	local best: { who: T, reason: Reason }? = nil
	for _, candidate in candidates do
		if best == nil or REASON_RANK[candidate.reason] < REASON_RANK[best.reason] then
			best = candidate
		end
	end
	if best == nil then
		return nil, nil
	end
	return best.who, best.reason
end

-- Seconds after the gate lands before the Creature hunts (seeded per run).
function Level1.releaseDelay(seed: number): number
	local random = MathUtil.seededRandom(seed, "L1_ClassroomScare:release")
	return random:NextNumber(CLASSROOM.ReleaseMin, CLASSROOM.ReleaseMax)
end

-- The point the body faces so its back is square to `eye` (the 180-degree snap then stares straight at it); nil when
-- the eye is right above the root.
function Level1.backTurn(root: Vector3, eye: Vector3): Vector3?
	local away = MathUtil.flat(root - eye)
	if away.Magnitude < 0.1 then
		return nil
	end
	return root + away.Unit * 4
end

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

local function findFixture(lightId: string): BasePart?
	for _, instance in CollectionService:GetTagged(Tags.LevelLight) do
		if instance.Name == lightId and instance:IsA("BasePart") and instance:GetAttribute(W.LevelId) == LEVEL then
			return instance
		end
	end
	return nil
end

local function creatureRootPart(): BasePart?
	local model = MonsterAIService.GetCreature()
	local root = if model then model:FindFirstChild(CreatureRigBuilder.PartNames.Root) else nil
	return if root and root:IsA("BasePart") then root else nil
end

local function realDependencies(): Dependencies
	return {
		now = function(): number
			return Workspace:GetServerTimeNow()
		end,
		players = function(): { Player }
			return LevelKit.playersOn(LEVEL)
		end,
		eyeOf = LevelKit.eyeOf,
		feetOf = LevelKit.feetOf,
		zoneOf = function(player: Player): string?
			local zone = player:GetAttribute(P.ZoneId)
			return if type(zone) == "string" then zone else nil
		end,
		onGlass = function(player: Player): boolean
			for part, tag in ZoneService.GetPlayerVolumes(player) do
				if tag == Tags.ScareTrigger and part:GetAttribute(W.TriggerId) == GLASS_TRIGGER then
					return true
				end
			end
			return false
		end,
		inVent = VentNetworkService.IsInVent,
		lineClear = LevelKit.lineClear,
		acquire = MonsterAIService.AcquireScripted,
		alert = MonsterAIService.Alert,
		creatureRoot = function(): CFrame?
			local root = creatureRootPart()
			return if root then root.CFrame else nil
		end,
		creatureModel = MonsterAIService.GetCreature,
		creatureHidden = function(): boolean
			local model = MonsterAIService.GetCreature()
			return model ~= nil and model:GetAttribute(Attributes.Creature.Hidden) == true
		end,
		gate = function(): Model?
			return DoorService.Get(LEVEL, GATE_ID)
		end,
		lockGate = function(gate: Model, seconds: number): boolean
			return DoorService.SetState(gate, GATE_STATE, seconds)
		end,
		oneShot = LevelKit.oneShot,
		emit = function(position: Vector3, kind: Enums.NoiseKind, source: Player?)
			NoiseAndDirectorService.Emit(position, kind, { sourcePlayer = source, levelId = LEVEL })
		end,
		fixture = findFixture,
	}
end

local deps: Dependencies = realDependencies()

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local geometry: Geometry? = nil
local schedule: Schedule = LevelKit.newSchedule()
local active = false
local runSeed = 0
local done = false -- the scare (or its fallback) has fired this run
local handle: Handle? = nil
local staged = false
local nextStageAt = -math.huge
local nextTickAt = -math.huge
local scene: Scene? = nil
local killed: { [BasePart]: number } = {} -- burst fixtures -> their BaseBrightness before the burst

local function geo(): Geometry?
	local cached = geometry
	if cached then
		return cached
	end
	local layout = Builder.getLayout(LEVEL)
	if not layout then
		log.error("no %s layout; the classroom scare cannot run", LEVEL)
		return nil
	end
	local built = Level1.geometry(layout)
	geometry = built
	return built
end

local function eyesOf(players: { Player }): { Vector3 }
	return LevelKit.eyes(players, deps.eyeOf)
end

-- Could anyone see a Creature whose root is at `root` (its eyes or its chest)?
local function seen(root: Vector3, eyes: { Vector3 }): boolean
	return LevelKit.seenBy(eyes, root + Vector3.new(0, STANDING_EYE, 0), deps.lineClear)
		or LevelKit.seenBy(eyes, root, deps.lineClear)
end

local function creatureEyes(): Vector3?
	local root = deps.creatureRoot()
	return if root then root.Position + Vector3.new(0, STAGED_EYE, 0) else nil
end

--------------------------------------------------------------------------------
-- Staging
--------------------------------------------------------------------------------

local function stage(h: Handle, g: Geometry)
	h:Teleport(g.pose)
	h:SetPose(STAGED_POSE)
	h:SetHidden(false)
	staged = true
	log.info("the Creature waits in %s", g.classroom)
end

-- Nobody sees the Creature where it is (unless it is hidden) or the corner it would appear in.
local function stagingUnseen(g: Geometry): boolean
	local eyes = eyesOf(deps.players())
	if seen(g.pose.Position, eyes) then
		return false
	end
	local root = deps.creatureRoot()
	return root == nil or deps.creatureHidden() or not seen(root.Position, eyes)
end

local function ensureStaged(now: number, g: Geometry)
	if staged or now < nextStageAt then
		return
	end
	nextStageAt = now + STAGE_RETRY
	if not stagingUnseen(g) then
		return
	end
	if handle == nil then
		handle = deps.acquire(TOKEN)
	end
	local h = handle
	if h then
		stage(h, g)
	end
end

--------------------------------------------------------------------------------
-- The scene
--------------------------------------------------------------------------------

local function killLights()
	local current = scene
	if current then
		current.lightsKilled = true
	end
	for _, id in BURST_LIGHTS do
		local fixture = deps.fixture(id)
		if fixture and killed[fixture] == nil then
			killed[fixture] = math.max(0, Attributes.getNumber(fixture, W.BaseBrightness, 0))
			fixture:SetAttribute(W.BaseBrightness, 0)
		end
	end
end

local function restoreLights()
	for fixture, base in killed do
		if fixture.Parent then
			fixture:SetAttribute(W.BaseBrightness, base)
		end
	end
	table.clear(killed)
end

local function lockGate(seconds: number)
	local current = scene
	if current then
		current.gateLocked = true
	end
	local gate = deps.gate()
	if not gate then
		log.warn("no %s on %s: the gate cannot close", GATE_ID, LEVEL)
		return
	end
	deps.lockGate(gate, seconds)
end

-- Moves the hidden Creature to the nearest patrol spot east of the gate that nobody sees and that is HIDE_DISTANCE
-- from every player. False when there is none right now (it stays hidden where it is).
local function relocate(g: Geometry): boolean
	local h, current = handle, scene
	if not (h and current) then
		return false
	end
	local root = deps.creatureRoot()
	local from = if root then root.Position else g.pose.Position
	local eyes = eyesOf(deps.players())
	local spot = LevelKit.hidingSpot(g.hidingSpots, eyes, from, HIDE_DISTANCE, function(point: Vector3): boolean
		return seen(point, eyes)
	end)
	h:SetPose(RELEASED_POSE)
	if not spot then
		return false
	end
	-- facing back toward the gate, the way it will come hunting
	local facing = Vector3.new(-1, 0, 0)
	h:Teleport(CFrame.lookAt(spot, spot + facing))
	current.relocated = true
	return true
end

local function release(g: Geometry)
	local h, current = handle, scene
	if not (h and current) then
		return
	end
	if not current.relocated then
		relocate(g)
	end
	handle = nil
	staged = false
	h:Release(RELEASE_STATE)
	deps.alert(g.alertPoint, ALERT_PRIORITY)
	log.info("the Creature is hunting")
end

local function scheduleFull(current: Scene, g: Geometry)
	local s = current.startAt
	schedule:At(s + CLASSROOM.Snap - CLASSROOM.FaceLead, "face", function()
		local h = handle
		local root = deps.creatureRoot()
		if not (h and root) then
			return
		end
		local eye = deps.eyeOf(current.subject) or current.triggerEye
		local target = Level1.backTurn(root.Position, eye)
		if target then
			h:Face(target)
		end
	end)
	schedule:At(s + CLASSROOM.Burst - LEAD, "burst", function()
		for index, light in g.lights do
			deps.oneShot(
				BURST_KIND,
				s + CLASSROOM.Burst + (index - 1) * CLASSROOM.SpillStagger,
				{ lightId = light.id },
				deps.fixture(light.id)
			)
		end
	end)
	schedule:At(s + CLASSROOM.Vanish - LEAD, "vanish", function()
		deps.oneShot(VANISH_KIND, s + CLASSROOM.Vanish, {}, deps.creatureModel())
	end)
	schedule:At(s + CLASSROOM.Hide, "hide", function()
		local h = handle
		if h then
			h:SetHidden(true)
		end
	end)
	schedule:At(s + CLASSROOM.KillLights, "lights", killLights)
	schedule:At(s + CLASSROOM.GateLand - LEAD - GATE_SECONDS, "gate", function()
		lockGate(GATE_SECONDS)
	end)
	schedule:At(s + CLASSROOM.Relocate, "relocate", function()
		relocate(g)
	end)
	schedule:At(s + CLASSROOM.GateLand + Level1.releaseDelay(runSeed), "release", function()
		release(g)
	end)
end

local function scheduleSkipped(current: Scene, g: Geometry)
	local s = current.startAt
	schedule:At(s + CLASSROOM.SkippedGateLand - LEAD - GATE_SECONDS, "gate", function()
		lockGate(GATE_SECONDS)
	end)
	if handle then
		-- held but never staged (it was in sight the whole time): let it go after the slam
		schedule:At(s + CLASSROOM.SkippedGateLand + Level1.releaseDelay(runSeed), "release", function()
			release(g)
		end)
	end
end

-- Sets the scene off with `subject` (why: `reason`) at `now`.
local function startScene(subject: Player, reason: Reason, now: number, g: Geometry)
	done = true
	local eye = deps.eyeOf(subject) or g.alertPoint
	local feet = deps.feetOf(subject) or g.alertPoint
	local full = handle ~= nil and staged
	local current: Scene = {
		startAt = now + LEAD,
		subject = subject,
		reason = reason,
		full = full,
		triggerEye = eye,
		gateLocked = false,
		lightsKilled = false,
		relocated = false,
	}
	scene = current
	deps.emit(feet, CRUNCH_NOISE, subject)
	if full then
		local head = creatureEyes() or (g.pose.Position + Vector3.new(0, STAGED_EYE, 0))
		local glow = g.lights[1]
		local spill = g.lights[2] or glow
		local args: { [string]: Types.OneShotArg } = {
			id = CLASSROOM.Id,
			[ARGS.Subject] = subject.UserId,
			[ARGS.Feet] = feet,
			[ARGS.Head] = head,
			[ARGS.Focus] = deps.lineClear(eye, head),
		}
		if glow then
			args[ARGS.Glow] = glow.position
		end
		if spill then
			args[ARGS.Spill] = spill.position
		end
		deps.oneShot(TIMELINE_KIND, current.startAt, args, nil)
		scheduleFull(current, g)
	else
		deps.oneShot(TIMELINE_KIND, current.startAt, {
			id = CLASSROOM.SkippedId,
			[ARGS.Subject] = subject.UserId,
			[ARGS.Feet] = feet,
		}, nil)
		scheduleSkipped(current, g)
	end
	log.info("classroom scare (%s) for %s%s", reason, subject.Name, if full then "" else ", the Creature was busy")
end

-- The participant setting the scare off this tick, if any.
local function findTrigger(g: Geometry): (Player?, Reason?)
	local head = if staged then creatureEyes() else nil
	local candidates: { { who: Player, reason: Reason } } = {}
	for _, player in deps.players() do
		local eye = deps.eyeOf(player)
		local sample: Sample = {
			onGlass = deps.onGlass(player),
			zone = deps.zoneOf(player),
			localX = if eye then eye.X - g.origin.X else nil,
			inVent = deps.inVent(player),
			distance = if eye and head then (eye - head).Magnitude else nil,
			sightline = false,
		}
		local near = sample.distance
		if eye and head and near and near <= NEAR_DISTANCE and not sample.inVent then
			sample.sightline = deps.lineClear(eye, head)
		end
		local reason: Reason? = Level1.triggerReason(sample, g)
		if reason ~= nil then
			local candidate: { who: Player, reason: Reason } = { who = player, reason = reason :: Reason }
			table.insert(candidates, candidate)
		end
	end
	return Level1.pickSubject(candidates)
end

-- Ends whatever is in flight. With `finish`, a scene cut short leaves the world as it would have: the gate shut, the
-- bulbs dead. A held Creature is let go into `parkState` (nil: dropped without a word, for a run that is over).
local function cancel(finish: boolean, parkState: Enums.MonsterState?)
	schedule:Clear()
	local current = scene
	if current and finish then
		if not current.gateLocked then
			lockGate(0)
		end
		if current.full and not current.lightsKilled then
			killLights()
		end
	end
	scene = nil
	local h = handle
	handle = nil
	staged = false
	if h and parkState then
		h:Release(parkState)
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- One step at `now` (the Levels service runs it every Heartbeat; specs call it with a fake clock): the scene's
-- scheduled beats on time, staging and the trigger at the server tick rate.
function Level1.Step(now: number?)
	local t = now or deps.now()
	schedule:Run(t)
	if not active or done or t < nextTickAt then
		return
	end
	nextTickAt = t + TICK
	local g = geo()
	if not g then
		return
	end
	ensureStaged(t, g)
	local subject: Player?, reason: Reason? = findTrigger(g)
	if subject and reason ~= nil then
		startScene(subject, reason :: Reason, t, g)
	end
end

-- Plays the scare now for `player` (dev). False when it already ran this run or the level is not active.
function Level1.Trigger(player: Player, reason: Reason?): boolean
	local g = geo()
	if not (active and not done and g) then
		return false
	end
	if handle == nil then
		handle = deps.acquire(TOKEN)
	end
	local h = handle
	if h and not staged then
		stage(h, g)
	end
	local why: Reason = reason or "Glass"
	startScene(player, why, deps.now(), g)
	return true
end

function Level1.HasRun(): boolean
	return done
end

function Level1.IsHolding(): boolean
	return handle ~= nil
end

function Level1.IsStaged(): boolean
	return staged
end

function Level1.GetGeometry(): Geometry?
	return geo()
end

-- Names of the scene beats still to come.
function Level1.Pending(): { string }
	return schedule:Pending()
end

function Level1.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
end

--------------------------------------------------------------------------------
-- Level controller + lifecycle (driven by the Levels service)
--------------------------------------------------------------------------------

-- LevelDirector: the squad is on Level 1.
function Level1.Activate(_ctx: Types.LevelContext)
	active = true
	nextTickAt = -math.huge
	nextStageAt = -math.huge
	if done then
		return
	end
	-- Taken now, so the brain never starts its own patrol here; placed on the next step, after the director's own
	-- activation handling (which may move a Creature arriving from another level).
	staged = false
	if handle == nil then
		handle = deps.acquire(TOKEN)
	end
end

-- LevelDirector: the squad left Level 1 (or the run ended).
function Level1.Deactivate()
	active = false
	cancel(true, PARKED_STATE)
end

local controller: Types.LevelController = {
	LevelId = LEVEL,
	Activate = Level1.Activate,
	Deactivate = Level1.Deactivate,
}
Level1.Controller = controller

local function scareCommand(player: Player, _args: { string }): string?
	if done then
		return "the classroom scare already ran this run"
	end
	if not active then
		return "go to Level 1 first (level 1)"
	end
	Level1.Trigger(player, "Glass")
	return if staged or scene ~= nil then "the classroom scare is playing" else "the scare is starting"
end

function Level1.Init()
	DevToolsService.Register(
		"scare",
		"scare: play Floor 1's classroom scare now, with you as the subject",
		scareCommand
	)
end

function Level1.BeginRun(ctx: Types.RunContext)
	cancel(false, nil)
	restoreLights()
	runSeed = ctx.seed
	done = false
	active = false
end

function Level1.EndRun()
	cancel(false, PARKED_STATE)
	restoreLights()
	done = false
	active = false
end

return table.freeze(Level1)
