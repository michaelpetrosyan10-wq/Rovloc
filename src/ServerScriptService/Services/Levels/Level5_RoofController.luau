--!strict
-- Level5_RoofController: the roof and the ending (spec, Level 5). The packs, the jump and the canopy are
-- ParachuteService's; this controller runs the level around them and owns the finale.
--
-- Arrival. On activation the Creature is taken (MonsterAIService.AcquireScripted(TOKEN); a Creature that is busy is
-- asked for again at the tick rate, and only taken while nobody can see it) and kept hidden in the stair housing
-- (MonsterAIService brought it to the level's CreatureSpawn there). The run arrives in one of three stair housings
-- (the route's Stairwell_4_5 candidate, LevelDirector.entryFor: L5_RoofAccess, L5_RoofAccessNorth or
-- L5_RoofAccessSouth, each with its own roof door, RoofStairDoor / RoofStairDoorNorth / RoofStairDoorSouth); the
-- finale plays at that one (geometry). Its roof door (DoorService; it starts Closed)
-- swings open OPEN_DELAY after the first playing participant reaches the housing at the top of the stairs.
--
-- The door smash (Scenes.RoofDoor, from startAt S). Once the squad is out on the roof (squadOut: every playing
-- participant out of the housing and the stair tower and DOOR_CLEAR from the doorway), or SMASH_TIMEOUT after the first
-- one stepped out, or ARRIVAL_TIMEOUT after activation whoever is where (smashDue): OneShot Timeline "L5_DoorSmash".
-- The wind slams the door shut so it lands at Slam (skipped while anyone is still inside or in the doorway: they are
-- never shut in with it), the hidden Creature is moved in right behind the door, facing it (Stage), three blows from
-- the far side, it is shown behind the closed door at Reveal (only while nobody can see that spot, so a straggler inside
-- never watches it pop in), DoorService Smashed so the leaf flies at Smash (the DoorSmash action with it), its cry, and
-- at Release it is let go into WallChase at the nearest player while everyone on the roof is told to run
-- (Hud.RoofRun).
--
-- The final sprint, from the release until the finale: the Creature's pace follows its gap to its target (chaseScale
-- through MonsterAIService.SetSpeedScale: it runs down a straggler and closes on anyone who stops, but it never quite
-- outruns a sprinter on Standard), and every Alive player still on the roof sprints on adrenaline (their stamina is
-- topped up whenever it falls under STAMINA_FLOOR).
--
-- The finale (Scenes.Finale, from startAt F). It starts (finaleReady) once someone has jumped, no Alive participant is
-- left on the roof to jump (a Downed one does not hold it), nobody is still in freefall and the last canopy has been
-- open Finale.Settle; or FINALE_WAIT after the first landing, whoever is still up there. The Creature is taken back
-- (up to ACQUIRE_WAIT while a catch finishes; without it only the storm plays, "L5_FinaleSky"), hidden, put on the
-- ledge the squad jumped from (revealPose: on the edge, facing out over them) and turned to stare at the jumper nearest
-- under it (stareTarget, MonsterAIService.SetScriptedTarget). OneShot Lightning at Flash1 and Flash2. It is shown in the
-- dark gap just before the first flash's main strike (Reveal: motionless, staring down) and hidden just before the
-- second's (Vanish: it glitches in the first strike; the main one lights an empty ledge). The clients fade to black. At
-- Land every jumper still under a canopy that opened before the fade is landed in the dark (ParachuteService.ForceLand)
-- and every lander's hold ends (ParachuteService.ReleaseHold: the view is theirs again, so the ESCAPED summary takes
-- over). The finale keeps playing if the run has already resolved (the last lander escaped): Results waits for it.
-- Anyone still on the roof after it is hunted again (Release Patrol + a High Alert at the nearest of them); with nobody
-- left the Creature stays held, hidden, until the run ends.
--
-- Escapes. A jumper escapes the moment they are down below under a canopy (or landed by the finale in the dark): Escaped
-- fires once, at the landing, so MatchAndDataService's escape time (their BestTime) is the touchdown. ParachuteService
-- holds the body (the "Parachute" control lock) until the finale has played for them, which holds the summary too.
-- A jumper who lands after the finale (they jumped late) gets their own fade ("L5_Touchdown", args.subject) and their
-- hold ends Finale.TouchdownRelease later.
--
-- No pack, no escape. The crate holds GameConfig.ParachutePackCount packs, one for every member of a full squad
-- (MaxSquad), and a pack goes back into it when its wearer dies or leaves before jumping, so every living participant
-- can always get one. A participant who jumps without one dies in the fall (warned at the gap); one who stays on the roof
-- keeps playing: they hold the finale while Alive (up to FINALE_WAIT after the first landing), and after it the Creature
-- hunts them until they jump with a pack, bleed out or are caught.
--
-- Deactivate and EndRun cancel everything scheduled, let a held Creature go (Dormant) and restore its pace.
--
-- Signals: Escaped(player): a jumper got away (the contract MatchAndDataService subscribes to through Levels.Level5).
-- Dev command: roof [smash|finale] (the door now, or the finale with whoever has jumped; no argument reports the phase).
--
-- Pure rules (tests/Specs/Roof.spec.luau): geometry, inside, squadOut, smashDue, chaseScale, finaleReady, revealPose,
-- stareTarget. SetDependencies swaps every service the controller touches, so specs run the level on a fake clock.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local ParachuteMotion = require(ReplicatedStorage.Shared.Sequence.ParachuteMotion)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local DoorService = require(ServerScriptService.Services.Mechanics.DoorService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local ParachuteService = require(ServerScriptService.Services.Mechanics.ParachuteService)

local LevelKit = require(script.Parent.LevelKit)

local log = Log.new("Level5")

type Handle = MonsterAIService.ScriptedHandle
type Schedule = LevelKit.Schedule
type Jump = ParachuteService.Jump

export type Rect = ParachuteMotion.Rect

export type Phase = "Idle" | "Arrival" | "Smash" | "Chase" | "FinaleWait" | "Finale" | "Done"

export type Geometry = {
	origin: Vector3,
	housing: Rect, -- the stair housing (L5_RoofAccess), world X / Z
	tower: Rect, -- the stair tower that comes up into it
	doorway: Vector3, -- the RoofStairDoor's centre on the housing wall, deck height
	out: Vector3, -- unit, from the housing out through the door onto the roof
	behind: CFrame, -- the Creature's spot right behind the door, facing it (root)
	cue: Vector3, -- where the door's sounds and shakes come from (roof side, mid-height)
}

export type Sample = { position: Vector3 }

export type SmashInput = {
	out: boolean, -- squadOut
	firstOutAt: number?, -- when the first participant stepped out of the housing
	activatedAt: number,
	now: number,
}

export type FinaleInput = {
	jumpers: number, -- under a canopy or down below
	falling: number, -- off the edge with a pack, cord not pulled yet
	roofAlive: number, -- Alive participants who have not jumped
	lastDeployAt: number?, -- when the most recent canopy opened
	firstLandedAt: number?,
	now: number,
}

export type Dependencies = {
	now: () -> number,
	players: () -> { Player }, -- the run's playing participants (Alive or Downed, with a body)
	rootOf: (player: Player) -> Vector3?,
	eyeOf: (player: Player) -> Vector3?,
	lineClear: (from: Vector3, to: Vector3) -> boolean,
	lifeState: (player: Player) -> Enums.LifeState,
	acquire: (token: string) -> Handle?,
	stare: (token: string, player: Player?) -> boolean,
	alert: (position: Vector3, priority: Enums.NoisePriority) -> (),
	creatureRoot: () -> Vector3?,
	creatureTarget: () -> Player?,
	setSpeedScale: (scale: number) -> (),
	door: () -> Model?,
	doorState: (door: Model) -> Enums.DoorState,
	setDoor: (door: Model, state: Enums.DoorState, seconds: number?) -> boolean,
	oneShot: (kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg }, subject: Instance?) -> (),
	jump: (player: Player) -> Jump?,
	forceLand: (player: Player) -> boolean,
	releaseHold: (player: Player) -> boolean,
	stamina: (player: Player) -> number,
	refillStamina: (player: Player) -> (),
	notify: (player: Player, key: string) -> (),
}

type SmashRun = { startAt: number, slammed: boolean, revealed: boolean, released: boolean }
type FinaleRun = { startAt: number, creature: boolean, done: boolean }

local LEVEL: Enums.LevelId = "Level5_Roof"
local TOKEN = "L5_RoofFinale"
local DOOR_ID = "RoofStairDoor"
local HOUSING_ROOM = "L5_RoofAccess"
local ROOF_SIDE_ROOM = "L5_Roof_East"
local TICK = 1 / GameConfig.ServerTickHz
local LEAD = GameConfig.OneShotLead
local OPEN_DELAY = 1.2 -- the wind takes the door this long after the first arrival in the housing
local OPEN_SECONDS = 1.4
local DOOR_CLEAR = 9 -- studs from the doorway everyone must be before it slams
local SMASH_TIMEOUT = 20
local ARRIVAL_TIMEOUT = 75
local BEHIND_DOOR = 3 -- studs behind the door the Creature stands for the blows
local STAMINA_FLOOR = 55
local FINALE_WAIT = 40
local ACQUIRE_WAIT = 1.5
local FINALE_PRE = 0.3 -- the ledge staging replicates before the finale's clock starts
local LEDGE_INSET = 1.2 -- the Creature stands this far in from the edge
local NEAR_GAP = 14 -- chaseScale: right behind its target
local FAR_GAP = 40 -- and well behind it
local SCALE_STEP = 0.02
local ROOT_HEIGHT = CreatureConfig.Rig.HipHeight + CreatureConfig.Rig.RootSize.Y / 2
local EYE_HEIGHT = CreatureConfig.EyeHeightAboveRoot.Biped
local CHEST_HEIGHT = 1.2
local BIPED: Enums.PoseMode = "Biped"
local CHASE_STATE: Enums.MonsterState = "WallChase"
local HUNT_STATE: Enums.MonsterState = "Patrol"
local PARKED_STATE: Enums.MonsterState = "Dormant"
local HUNT_PRIORITY: Enums.NoisePriority = "High"
local TIMELINE_KIND: Enums.OneShotKind = "Timeline"
local LIGHTNING_KIND: Enums.OneShotKind = "Lightning"
local RUN_KEY = "Hud.RoofRun"
local DOOR = Scenes.RoofDoor
local FINALE = Scenes.Finale
local ROOF_ARGS = Scenes.RoofArgs
local ON_ROOF: { [string]: boolean } = { None = true, Packed = true }

-- The pace a chasing Creature keeps right behind / well behind its target, as a share of a sprinting player's speed.
local PACE: { [string]: { near: number, far: number } } = {
	Standard = { near = 0.96, far = 1.3 },
	Nightmare = { near = 1.02, far = 1.45 },
}

local Level5 = {}

Level5.LevelId = LEVEL
Level5.Token = TOKEN
Level5.OpenDelay = OPEN_DELAY
Level5.DoorClear = DOOR_CLEAR
Level5.SmashTimeout = SMASH_TIMEOUT
Level5.ArrivalTimeout = ARRIVAL_TIMEOUT
Level5.StaminaFloor = STAMINA_FLOOR
Level5.FinaleWait = FINALE_WAIT
Level5.AcquireWait = ACQUIRE_WAIT
Level5.FinalePre = FINALE_PRE
Level5.LedgeInset = LEDGE_INSET
Level5.RunKey = RUN_KEY

local escapedSignal: Signal.Signal<Player> = Signal.new()

-- (player) once per run when a jumper got away: the moment they are down below under a canopy (or landed by the
-- finale's scripted landing in the dark). MatchAndDataService takes that moment as their escape time.
Level5.Escaped = escapedSignal

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

local function worldRect(origin: Vector3, r: LayoutSchema.Rect): Rect
	return { minX = origin.X + r.x, maxX = origin.X + r.x + r.w, minZ = origin.Z + r.z, maxZ = origin.Z + r.z + r.d }
end

local function inRect(rect: Rect, position: Vector3): boolean
	return position.X >= rect.minX and position.X <= rect.maxX and position.Z >= rect.minZ and position.Z <= rect.maxZ
end

-- The roof door of the housing `arrival` (a Stairwell_4_5 candidate; nil: the middle one) leads up to.
function Level5.roofDoor(layout: LayoutSchema.LevelLayout, arrival: WorldConfig.StairwellSpec?): LayoutSchema.Door?
	local housingId = if arrival then arrival.toRoom else HOUSING_ROOM
	for _, candidate in layout.doors do
		if candidate.kind == "RoofDoor" and table.find(candidate.rooms, housingId) and candidate.scriptedId then
			return candidate
		end
	end
	return nil
end

-- The ScriptedId of the roof door the run arrives behind (DoorService.Get on the roof).
function Level5.doorId(layout: LayoutSchema.LevelLayout?, arrival: WorldConfig.StairwellSpec?): string
	local door = if layout then Level5.roofDoor(layout, arrival) else nil
	return if door and door.scriptedId then door.scriptedId else DOOR_ID
end

-- Everything the level needs from the roof's blueprint (world positions), for a squad arriving by `arrival` (a
-- Stairwell_4_5 candidate; nil: the middle one).
function Level5.geometry(layout: LayoutSchema.LevelLayout, arrival: WorldConfig.StairwellSpec?): Geometry
	local origin = WorldConfig.levelOrigin(layout.id)
	local rooms = LayoutSchema.indexRooms(layout)
	local housingId = if arrival then arrival.toRoom else HOUSING_ROOM
	local housing = rooms[housingId]
	local roofSide = rooms[ROOF_SIDE_ROOM]
	assert(housing and roofSide, "Level 5 has no " .. housingId .. " / " .. ROOF_SIDE_ROOM)
	local door = Level5.roofDoor(layout, arrival)
	assert(door, "Level 5 has no roof door on " .. housingId)
	local edge = LayoutSchema.sharedEdge(housing.rect, roofSide.rect)
	assert(edge, housingId .. " and " .. ROOF_SIDE_ROOM .. " share no wall")
	local at = door.at
	local doorway = if edge.axis == "X"
		then origin + Vector3.new(edge.coord, 0, at)
		else origin + Vector3.new(at, 0, edge.coord)
	local centre = LayoutSchema.rectCenter(housing.rect)
	local fromCentre = MathUtil.flat(doorway - (origin + Vector3.new(centre.X, 0, centre.Y)))
	local out = if edge.axis == "X"
		then Vector3.new(if fromCentre.X < 0 then -1 else 1, 0, 0)
		else Vector3.new(0, 0, if fromCentre.Z < 0 then -1 else 1)
	local spot = doorway - out * BEHIND_DOOR + Vector3.new(0, ROOT_HEIGHT, 0)
	local towerSpec = arrival or WorldConfig.routeEntry(nil, layout.id)
	local tower = WorldConfig.Towers[if towerSpec then towerSpec.tower else "East"]
	local school = WorldConfig.SchoolOrigin
	return {
		origin = origin,
		housing = worldRect(origin, housing.rect),
		tower = {
			minX = school.X + tower.minX,
			maxX = school.X + tower.maxX,
			minZ = school.Z + tower.minZ,
			maxZ = school.Z + tower.maxZ,
		},
		doorway = doorway,
		out = out,
		behind = CFrame.lookAt(spot, spot + out),
		cue = doorway + out + Vector3.new(0, 4, 0),
	}
end

-- Whether a root at `position` is still in the stair housing or the stair tower below it.
function Level5.inside(position: Vector3, g: Geometry): boolean
	return inRect(g.housing, position) or inRect(g.tower, position)
end

-- Whether everyone is out on the roof and clear of the door (the door may slam), and whether anyone is out at all.
function Level5.squadOut(samples: { Sample }, g: Geometry): (boolean, boolean)
	local anyOut = false
	local allOut = #samples > 0
	for _, sample in samples do
		local inside = Level5.inside(sample.position, g)
		if not inside then
			anyOut = true
		end
		if inside or MathUtil.horizontalDistance(sample.position, g.doorway) < DOOR_CLEAR then
			allOut = false
		end
	end
	return allOut, anyOut
end

-- Whether the door sequence starts now (see the header).
function Level5.smashDue(input: SmashInput): boolean
	if input.out then
		return true
	end
	local firstOut = input.firstOutAt
	if firstOut ~= nil and input.now >= firstOut + SMASH_TIMEOUT then
		return true
	end
	return input.now >= input.activatedAt + ARRIVAL_TIMEOUT
end

-- The chasing Creature's speed scale for a gap of `gap` studs to its target (nil: no target, as configured): from the
-- difficulty's near pace (right behind) to its far pace (well behind), relative to its WallChase speed.
function Level5.chaseScale(gap: number?, difficulty: Enums.Difficulty): number
	if gap == nil then
		return 1
	end
	local pace = PACE[difficulty] or PACE.Standard
	local spec = DifficultyConfig[difficulty] or DifficultyConfig.Standard
	local base = CreatureConfig.Speeds.WallChase * spec.creatureSpeedMultiplier
	local share = MathUtil.lerp(pace.near, pace.far, MathUtil.clamp01((gap - NEAR_GAP) / (FAR_GAP - NEAR_GAP)))
	local scale = share * GameConfig.SprintSpeed / base
	return math.clamp(MathUtil.round(scale, SCALE_STEP), 0.5, 2)
end

-- Whether the finale starts now (see the header).
function Level5.finaleReady(input: FinaleInput): boolean
	if input.jumpers + input.falling == 0 then
		return false
	end
	local firstLanded = input.firstLandedAt
	if firstLanded ~= nil and input.now >= firstLanded + FINALE_WAIT then
		return true
	end
	if input.jumpers == 0 or input.roofAlive > 0 or input.falling > 0 then
		return false
	end
	local lastDeploy = input.lastDeployAt
	return lastDeploy == nil or input.now >= lastDeploy + FINALE.Settle
end

-- Where the Creature stands for the reveal: on the ledge nearest where the squad left the roof (the average of
-- `leftFrom`; the jump gap when nobody did), LedgeInset in from the edge, facing out over them.
function Level5.revealPose(leftFrom: { Vector3 }): CFrame
	local sum = Vector3.zero
	for _, point in leftFrom do
		sum += point
	end
	local gap = ParachuteMotion.Gap
	local from = if #leftFrom > 0
		then sum / #leftFrom
		else Vector3.new(gap.minX, ParachuteMotion.DeckY, (gap.minZ + gap.maxZ) / 2)
	local edge = ParachuteMotion.edgePoint(from)
	local outward = ParachuteMotion.outward(from)
	local spot = edge - outward * LEDGE_INSET + Vector3.new(0, ROOT_HEIGHT, 0)
	return CFrame.lookAt(spot, spot + outward)
end

-- The jumper whose root is nearest the ledge horizontally (the one right under the Creature's stare), or nil.
function Level5.stareTarget<T>(jumpers: { { who: T, position: Vector3 } }, ledge: Vector3): T?
	local best: T? = nil
	local bestDistance = math.huge
	for _, entry in jumpers do
		local distance = MathUtil.horizontalDistance(entry.position, ledge)
		if distance < bestDistance then
			best, bestDistance = entry.who, distance
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Dependencies + state
--------------------------------------------------------------------------------

local function realDependencies(): Dependencies
	return {
		now = function(): number
			return Workspace:GetServerTimeNow()
		end,
		players = LevelKit.playingParticipants,
		rootOf = LevelKit.rootOf,
		eyeOf = LevelKit.eyeOf,
		lineClear = LevelKit.lineClear,
		lifeState = LifeStateService.GetState,
		acquire = MonsterAIService.AcquireScripted,
		stare = MonsterAIService.SetScriptedTarget,
		alert = MonsterAIService.Alert,
		creatureRoot = function(): Vector3?
			local model = MonsterAIService.GetCreature()
			local root = if model then model:FindFirstChild("HumanoidRootPart") else nil
			return if root and root:IsA("BasePart") then root.CFrame.Position else nil
		end,
		creatureTarget = MonsterAIService.GetTarget,
		setSpeedScale = MonsterAIService.SetSpeedScale,
		door = function(): Model?
			return DoorService.Get(LEVEL, Level5.doorId(Builder.getLayout(LEVEL), LevelDirector.entryFor(LEVEL)))
		end,
		doorState = DoorService.GetState,
		setDoor = DoorService.SetState,
		oneShot = LevelKit.oneShot,
		jump = ParachuteService.GetJump,
		forceLand = ParachuteService.ForceLand,
		releaseHold = ParachuteService.ReleaseHold,
		stamina = PlayerStateService.GetStamina,
		refillStamina = PlayerStateService.RefillStamina,
		notify = LevelKit.notify,
	}
end

local deps: Dependencies = realDependencies()

local geometry: Geometry? = nil
local geometryRoom: string? = nil -- the housing `geometry` was built for
local schedule: Schedule = LevelKit.newSchedule()
local active = false
local phase: Phase = "Idle"
local difficulty: Enums.Difficulty = "Standard"
local handle: Handle? = nil
local activatedAt = 0
local arrivedAt: number? = nil
local firstOutAt: number? = nil
local doorOpened = false
local smashRun: SmashRun? = nil
local finaleRun: FinaleRun? = nil
local acquireUntil = 0
local nextTickAt = -math.huge
local scaleSet = 1
local escaped: { [Player]: boolean } = {}
local landedAt: { [Player]: number } = {}
local touchdowns: { [Player]: boolean } = {}

local function geo(): Geometry?
	local arrival = LevelDirector.entryFor(LEVEL)
	local room = if arrival then arrival.toRoom else HOUSING_ROOM
	local cached = geometry
	if cached and geometryRoom == room then
		return cached
	end
	local layout = Builder.getLayout(LEVEL)
	if not layout then
		log.error("no %s layout; the roof cannot run", LEVEL)
		return nil
	end
	local built = Level5.geometry(layout, arrival)
	geometry = built
	geometryRoom = room
	return built
end

local function jumpState(player: Player): Enums.ParachuteState
	local jump = deps.jump(player)
	return if jump then jump.state else "None"
end

local function eyes(players: { Player }): { Vector3 }
	return LevelKit.eyes(players, deps.eyeOf)
end

-- Could anyone see a Creature whose root is at `root` (its eyes or its chest)?
local function seen(root: Vector3, players: { Player }): boolean
	local list = eyes(players)
	return LevelKit.seenBy(list, root + Vector3.new(0, EYE_HEIGHT, 0), deps.lineClear)
		or LevelKit.seenBy(list, root + Vector3.new(0, CHEST_HEIGHT, 0), deps.lineClear)
end

local function setScale(scale: number)
	if math.abs(scale - scaleSet) < 1e-6 then
		return
	end
	scaleSet = scale
	deps.setSpeedScale(scale)
end

local function escape(player: Player)
	if escaped[player] then
		return
	end
	escaped[player] = true
	log.info("%s escaped", player.Name)
	escapedSignal:Fire(player)
end

-- Lets a held Creature go into `state` (nil: just drops the hold for a run that is over).
local function letGo(state: Enums.MonsterState?)
	local h = handle
	handle = nil
	if not h then
		return
	end
	deps.stare(TOKEN, nil)
	if state then
		h:Release(state)
	end
end

--------------------------------------------------------------------------------
-- Arrival + the door
--------------------------------------------------------------------------------

-- Takes the Creature when it is free and nobody is watching it (it vanishes into the housing for the door).
local function ensureHeld(players: { Player })
	if handle ~= nil or phase ~= "Arrival" then
		return
	end
	local root = deps.creatureRoot()
	if root and seen(root, players) then
		return
	end
	local h = deps.acquire(TOKEN)
	if h then
		handle = h
		h:SetHidden(true)
	end
end

local function samplesOf(players: { Player }): { Sample }
	local out: { Sample } = {}
	for _, player in players do
		local root = deps.rootOf(player)
		if root then
			table.insert(out, { position = root })
		end
	end
	return out
end

local function startSmash(now: number, g: Geometry)
	phase = "Smash"
	local startAt = now + LEAD
	local run: SmashRun = { startAt = startAt, slammed = false, revealed = false, released = false }
	smashRun = run
	local players = deps.players()
	local blocked = false
	for _, sample in samplesOf(players) do
		if
			Level5.inside(sample.position, g)
			or MathUtil.horizontalDistance(sample.position, g.doorway) < DOOR_CLEAR
		then
			blocked = true
		end
	end
	local args: { [string]: Types.OneShotArg } = { id = DOOR.Id, [ROOF_ARGS.Door] = g.cue }
	deps.oneShot(TIMELINE_KIND, startAt, args, nil)
	local door = deps.door()
	if door and not blocked and deps.doorState(door) == "Open" then
		run.slammed = deps.setDoor(door, "Closed", DOOR.SlamSeconds)
	end
	schedule:At(startAt + DOOR.Stage, "stage", function()
		local h = handle
		if h then
			h:SetHidden(true)
			h:SetPose(BIPED)
			h:Teleport(g.behind)
		end
	end)
	schedule:At(startAt + DOOR.Reveal, "reveal", function()
		local h = handle
		if h and not seen(g.behind.Position, deps.players()) then
			h:SetHidden(false)
			run.revealed = true
		end
	end)
	schedule:At(startAt + DOOR.Smash - LEAD, "smash", function()
		local current = deps.door()
		if current then
			deps.setDoor(current, "Smashed", nil)
		end
	end)
	schedule:At(startAt + DOOR.Release, "release", function()
		run.released = true
		if phase == "Smash" then
			phase = "Chase"
		end
		letGo(CHASE_STATE)
		for _, player in deps.players() do
			if ON_ROOF[jumpState(player)] then
				deps.notify(player, RUN_KEY)
			end
		end
		log.info("the Creature is through the roof door")
	end)
	log.info("the roof door sequence starts%s", if blocked then " (someone is still inside)" else "")
end

local function stepArrival(now: number, g: Geometry, players: { Player })
	local samples = samplesOf(players)
	local anyInHousing = false
	for _, sample in samples do
		if inRect(g.housing, sample.position) then
			anyInHousing = true
		end
	end
	if anyInHousing and arrivedAt == nil then
		arrivedAt = now
	end
	local arrived = arrivedAt
	if not doorOpened and arrived ~= nil and now >= arrived + OPEN_DELAY then
		doorOpened = true
		local door = deps.door()
		if door and deps.doorState(door) == "Closed" then
			deps.setDoor(door, "Open", OPEN_SECONDS)
		end
	end
	local out, anyOut = Level5.squadOut(samples, g)
	if anyOut and firstOutAt == nil then
		firstOutAt = now
	end
	if Level5.smashDue({ out = out, firstOutAt = firstOutAt, activatedAt = activatedAt, now = now }) then
		startSmash(now, g)
	end
end

--------------------------------------------------------------------------------
-- The final sprint
--------------------------------------------------------------------------------

local function stepChase(players: { Player })
	local target = deps.creatureTarget()
	local creature = deps.creatureRoot()
	local targetRoot = if target then deps.rootOf(target) else nil
	local gap = if creature and targetRoot then MathUtil.horizontalDistance(creature, targetRoot) else nil
	setScale(Level5.chaseScale(gap, difficulty))
	for _, player in players do
		if ON_ROOF[jumpState(player)] and deps.lifeState(player) == "Alive" then
			if deps.stamina(player) < STAMINA_FLOOR then
				deps.refillStamina(player)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- The finale
--------------------------------------------------------------------------------

local function land(run: FinaleRun)
	local players = deps.players()
	for _, player in players do
		local jump = deps.jump(player)
		local opened = if jump then jump.deployedAt else nil
		if
			jump
			and (jump.state == "Canopy" or jump.state == "Freefall")
			and opened ~= nil
			and opened <= run.startAt + FINALE.FadeStart
		then
			deps.forceLand(player)
		end
	end
	local stragglers: { Player } = {}
	for _, player in players do
		local state = jumpState(player)
		if state == "Landed" then
			if landedAt[player] == nil then
				landedAt[player] = deps.now()
			end
			escape(player)
			deps.releaseHold(player)
		elseif ON_ROOF[state] then
			table.insert(stragglers, player)
		end
	end
	run.done = true
	phase = "Done"
	if #stragglers == 0 or handle == nil then
		return
	end
	local creature = deps.creatureRoot()
	local nearest: Vector3? = nil
	local nearestDistance = math.huge
	for _, player in stragglers do
		local root = deps.rootOf(player)
		if root then
			local distance = if creature then (root - creature).Magnitude else 0
			if distance < nearestDistance then
				nearest, nearestDistance = root, distance
			end
		end
	end
	letGo(HUNT_STATE)
	if nearest then
		deps.alert(nearest, HUNT_PRIORITY)
	end
	log.info("%d left on the roof: the Creature hunts them", #stragglers)
end

local function beginFinale(now: number, withCreature: boolean)
	phase = "Finale"
	local startAt = now + LEAD + FINALE_PRE
	local run: FinaleRun = { startAt = startAt, creature = withCreature, done = false }
	finaleRun = run
	local leftFrom: { Vector3 } = {}
	local below: { { who: Player, position: Vector3 } } = {}
	for _, player in deps.players() do
		local jump = deps.jump(player)
		if
			jump
			and jump.leftFrom
			and (jump.state == "Canopy" or jump.state == "Landed" or jump.state == "Freefall")
		then
			table.insert(leftFrom, jump.leftFrom :: Vector3)
			local root = deps.rootOf(player)
			if root then
				table.insert(below, { who = player, position = root })
			end
		end
	end
	local pose = Level5.revealPose(leftFrom)
	local head = pose.Position + Vector3.new(0, EYE_HEIGHT, 0)
	local h = if withCreature then handle else nil
	if h then
		h:SetHidden(true)
		h:SetPose(BIPED)
		h:Teleport(pose)
		h:Face(pose.Position + pose.LookVector * 6)
		local target = Level5.stareTarget(below, pose.Position)
		if target then
			deps.stare(TOKEN, target)
		end
	end
	local args: { [string]: Types.OneShotArg } = {
		id = if h then FINALE.Id else FINALE.SkyId,
		[ROOF_ARGS.Head] = head,
		[ROOF_ARGS.Ledge] = pose.Position,
	}
	deps.oneShot(TIMELINE_KIND, startAt, args, nil)
	local flash: { [string]: Types.OneShotArg } = { intensity = FINALE.FlashIntensity, stages = 2 }
	deps.oneShot(LIGHTNING_KIND, startAt + FINALE.Flash1, flash, nil)
	deps.oneShot(LIGHTNING_KIND, startAt + FINALE.Flash2, table.clone(flash), nil)
	if h then
		schedule:At(startAt + FINALE.Reveal - FINALE.RevealLead, "reveal", function()
			local current = handle
			if current then
				current:SetHidden(false)
			end
		end)
		schedule:At(startAt + FINALE.Hide - FINALE.HideLead, "vanish", function()
			local current = handle
			if current then
				current:SetHidden(true)
				deps.stare(TOKEN, nil)
			end
		end)
	end
	schedule:At(startAt + FINALE.Land, "land", function()
		land(run)
	end)
	log.info("the finale starts%s", if h then "" else " (the Creature could not be taken: the storm alone)")
end

local function startFinale(now: number)
	-- a door sequence still running is called off: nobody is left up there to chase, the Creature goes to the ledge
	schedule:Clear()
	setScale(1)
	if handle == nil then
		handle = deps.acquire(TOKEN)
	end
	if handle == nil then
		phase = "FinaleWait"
		acquireUntil = now + ACQUIRE_WAIT
		return
	end
	beginFinale(now, true)
end

local function stepFinaleWait(now: number)
	if handle == nil then
		handle = deps.acquire(TOKEN)
	end
	if handle ~= nil then
		beginFinale(now, true)
	elseif now >= acquireUntil then
		beginFinale(now, false)
	end
end

local function checkFinale(now: number, players: { Player })
	local jumpers, falling, roofAlive = 0, 0, 0
	local lastDeploy: number? = nil
	for _, player in players do
		local jump = deps.jump(player)
		local state = if jump then jump.state else "None"
		if state == "Canopy" or state == "Landed" then
			jumpers += 1
			local opened = if jump then jump.deployedAt else nil
			if state == "Canopy" and opened ~= nil and (lastDeploy == nil or opened > lastDeploy) then
				lastDeploy = opened
			end
		elseif state == "Freefall" then
			falling += 1
		elseif ON_ROOF[state] and deps.lifeState(player) == "Alive" then
			roofAlive += 1
		end
	end
	local firstLanded: number? = nil
	for _, at in landedAt do
		if firstLanded == nil or at < firstLanded then
			firstLanded = at
		end
	end
	if
		Level5.finaleReady({
			jumpers = jumpers,
			falling = falling,
			roofAlive = roofAlive,
			lastDeployAt = lastDeploy,
			firstLandedAt = firstLanded,
			now = now,
		})
	then
		startFinale(now)
	end
end

-- Landings: each jumper escapes the moment they are first seen down below; after the finale, a late lander gets their
-- own fade and their hold ends after it.
local function noteLandings(now: number, players: { Player })
	for _, player in players do
		if jumpState(player) ~= "Landed" or landedAt[player] ~= nil then
			continue
		end
		landedAt[player] = now
		escape(player)
		local run = finaleRun
		if run and run.done and not touchdowns[player] then
			touchdowns[player] = true
			local startAt = now + LEAD
			local args: { [string]: Types.OneShotArg } =
				{ id = FINALE.TouchdownId, [ROOF_ARGS.Subject] = player.UserId }
			deps.oneShot(TIMELINE_KIND, startAt, args, nil)
			schedule:At(startAt + FINALE.TouchdownRelease, "touchdown", function()
				deps.releaseHold(player)
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- One step at `now` (the Levels service runs it every Heartbeat; specs call it with a fake clock): scheduled beats on
-- time, the level's checks at the server tick rate.
function Level5.Step(now: number?)
	local t = now or deps.now()
	schedule:Run(t)
	if not active or t < nextTickAt then
		return
	end
	nextTickAt = t + TICK
	local g = geo()
	if not g then
		return
	end
	local players = deps.players()
	noteLandings(t, players)
	if phase == "Arrival" then
		ensureHeld(players)
		stepArrival(t, g, players)
	elseif phase == "Chase" then
		stepChase(players)
	elseif phase == "FinaleWait" then
		stepFinaleWait(t)
		return
	end
	if phase == "Arrival" or phase == "Smash" or phase == "Chase" then
		checkFinale(t, players)
	end
end

function Level5.GetPhase(): Phase
	return phase
end

function Level5.IsHolding(): boolean
	return handle ~= nil
end

function Level5.HasEscaped(player: Player): boolean
	return escaped[player] == true
end

function Level5.GetGeometry(): Geometry?
	return geo()
end

-- The door sequence of this run so far (nil before it started): whether the wind slammed the door, the Creature was
-- shown behind it and let go.
function Level5.GetSmash(): { startAt: number, slammed: boolean, revealed: boolean, released: boolean }?
	local run = smashRun
	if not run then
		return nil
	end
	return { startAt = run.startAt, slammed = run.slammed, revealed = run.revealed, released = run.released }
end

-- When the finale started (its startAt) and whether the Creature was in it; nil before it.
function Level5.GetFinale(): { startAt: number, creature: boolean, done: boolean }?
	local run = finaleRun
	if not run then
		return nil
	end
	return { startAt = run.startAt, creature = run.creature, done = run.done }
end

-- Names of the beats still to come.
function Level5.Pending(): { string }
	return schedule:Pending()
end

-- Starts the door sequence now (dev). False unless the squad is still arriving.
function Level5.Smash(): boolean
	local g = geo()
	if not (active and phase == "Arrival" and g) then
		return false
	end
	startSmash(deps.now(), g)
	return true
end

-- Starts the finale now (dev). False unless the level is live, someone has jumped and it has not played.
function Level5.PlayFinale(): boolean
	if not (active and (phase == "Arrival" or phase == "Smash" or phase == "Chase")) then
		return false
	end
	local anyone = false
	for _, player in deps.players() do
		local state = jumpState(player)
		if state == "Canopy" or state == "Landed" or state == "Freefall" then
			anyone = true
		end
	end
	if not anyone then
		return false
	end
	startFinale(deps.now())
	return true
end

function Level5.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
end

--------------------------------------------------------------------------------
-- Level controller + lifecycle (driven by the Levels service)
--------------------------------------------------------------------------------

local function cancel(parkState: Enums.MonsterState?)
	schedule:Clear()
	letGo(parkState)
	setScale(1)
	smashRun = nil
end

-- LevelDirector: the squad is on the roof. The Creature is taken now, before the brain's own activation handling (which
-- brings it to the level's spawn in the housing, hidden), so it never starts a patrol here.
function Level5.Activate(_ctx: Types.LevelContext)
	active = true
	phase = "Arrival"
	nextTickAt = -math.huge
	activatedAt = deps.now()
	arrivedAt = nil
	firstOutAt = nil
	doorOpened = false
	smashRun = nil
	finaleRun = nil
	if handle == nil then
		local h = deps.acquire(TOKEN)
		if h then
			handle = h
			h:SetHidden(true)
		end
	end
end

-- LevelDirector: the squad left the roof (a dev skip) or the run ended.
function Level5.Deactivate()
	active = false
	phase = "Idle"
	cancel(PARKED_STATE)
end

local controller: Types.LevelController = {
	LevelId = LEVEL,
	Activate = Level5.Activate,
	Deactivate = Level5.Deactivate,
}
Level5.Controller = controller

local function roofCommand(_player: Player, args: { string }): string?
	local action = string.lower(args[1] or "")
	if action == "smash" then
		return if Level5.Smash() then "the roof door sequence is playing" else "only while the squad is arriving"
	elseif action == "finale" then
		return if Level5.PlayFinale()
			then "the finale is playing"
			else "the finale needs someone off the roof with a pack (chute give, then jump) and must not have played"
	end
	return string.format(
		"roof: %s%s. usage: roof smash | finale",
		phase,
		if handle then ", holding the Creature" else ""
	)
end

function Level5.Init()
	DevToolsService.Register("roof", "roof [smash|finale]: the roof door sequence or the finale now", roofCommand)
end

local function resetState()
	active = false
	phase = "Idle"
	arrivedAt = nil
	firstOutAt = nil
	doorOpened = false
	smashRun = nil
	finaleRun = nil
	acquireUntil = 0
	nextTickAt = -math.huge
	table.clear(escaped)
	table.clear(landedAt)
	table.clear(touchdowns)
end

function Level5.BeginRun(ctx: Types.RunContext)
	cancel(nil)
	resetState()
	difficulty = ctx.difficulty
	scaleSet = 1
end

function Level5.EndRun()
	cancel(PARKED_STATE)
	resetState()
end

return table.freeze(Level5)
