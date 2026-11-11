--!strict
-- Level3_RoofController: the roof (spec, Level 3). The packs, the jump and the canopy are ParachuteService's; this
-- controller runs the level around them.
--
-- Arrival. On activation the Creature is taken (MonsterAIService.AcquireScripted(TOKEN); a Creature that is busy is
-- asked for again at the tick rate, and only taken while nobody can see it) and kept hidden in the stair housing
-- (MonsterAIService brought it to the level's CreatureSpawn there). The run arrives in one of three stair housings
-- (the route's Stairwell_2_3 candidate, LevelDirector.entryFor: L3_RoofAccess, L3_RoofAccessNorth or
-- L3_RoofAccessSouth, each with its own roof door, RoofStairDoor / RoofStairDoorNorth / RoofStairDoorSouth); the door
-- smash plays at that one (geometry). Its roof door (DoorService; it starts Closed) swings open OPEN_DELAY after the
-- first playing participant reaches the housing at the top of the stairs.
--
-- The door smash (Scenes.RoofDoor, from startAt S). The Creature waits behind the door for its grace
-- (ObjectiveConfig.graceFor: 20 s Standard, 12 s Nightmare) once the first playing participant has stepped out of the
-- housing, ended early by a High / Critical noise of a participant's on the roof after that; or ARRIVAL_TIMEOUT after
-- activation whoever is where (smashDue): OneShot Timeline "L3_DoorSmash".
-- The wind slams the door shut so it lands at Slam (skipped while anyone is still inside or in the doorway: they are
-- never shut in with it), the hidden Creature is moved in right behind the door, facing it (Stage), three blows from
-- the far side, it is shown behind the closed door at Reveal (only while nobody can see that spot, so a straggler inside
-- never watches it pop in), DoorService Smashed so the leaf flies at Smash (the DoorSmash action with it), its cry, and
-- at Release it is let go: into WallChase when someone can be seen from behind the doorway, else into Patrol (its senses
-- find them; it is never told where they are), and everyone on the roof is told to run (Hud.RoofRun).
--
-- The ledge staging. Once someone has jumped and no Alive participant is left on the roof to jump (a Downed one does
-- not hold it), LEDGE_DELAY after the last one left, the Creature is taken back (a busy one is asked for again at the
-- tick rate), put on the ledge the squad jumped from (revealPose: on the edge, facing out over them), shown, and turned
-- to stare at the jumper nearest under it (stareTarget, MonsterAIService.SetScriptedTarget): the look-back camera of
-- everyone under a canopy finds it there. It stays there, held, until the run ends.
--
-- Escapes. A jumper escapes the moment they are down below (or set down by ParachuteService.ForceLand): Escaped fires
-- once, at the landing, so MatchAndDataService's escape time (their BestTime) is the touchdown, and their hold ends at
-- once (ParachuteService.ReleaseHold). Nobody jumps without a pack: ParachuteService buckles a spare one onto anyone
-- who leaves the roof without one. Anyone who stays on the roof keeps playing: the Creature hunts them until they jump,
-- bleed out or are caught.
--
-- Deactivate and EndRun cancel everything scheduled and let a held Creature go (Dormant).
--
-- Signals: Escaped(player): a jumper got away (the contract MatchAndDataService subscribes to through Levels.Level3).
-- Dev command: roof [smash|ledge] (the door now, or the ledge staging once someone has jumped; no argument reports the
-- phase).
--
-- Pure rules (tests/Specs/Roof.spec.luau): geometry, inside, squadOut, smashDue, ledgeReady, revealPose, stareTarget.
-- SetDependencies swaps every service the controller touches, so specs run the level on a fake clock.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local ObjectiveConfig = require(ReplicatedStorage.Shared.Config.ObjectiveConfig)
local ParachuteMotion = require(ReplicatedStorage.Shared.Sequence.ParachuteMotion)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local DoorService = require(ServerScriptService.Services.Mechanics.DoorService)
local LevelDirector = require(ServerScriptService.Services.Core.LevelDirector)
local ParachuteService = require(ServerScriptService.Services.Mechanics.ParachuteService)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)

local LevelKit = require(script.Parent.LevelKit)

local log = Log.new("Level3")

type Handle = MonsterAIService.ScriptedHandle
type Schedule = LevelKit.Schedule
type Jump = ParachuteService.Jump

export type Rect = ParachuteMotion.Rect

export type Phase = "Idle" | "Arrival" | "Smash" | "Chase" | "Ledge"

export type Geometry = {
	origin: Vector3,
	housing: Rect, -- the stair housing (L3_RoofAccess), world X / Z
	tower: Rect, -- the stair tower that comes up into it
	doorway: Vector3, -- the RoofStairDoor's centre on the housing wall, deck height
	out: Vector3, -- unit, from the housing out through the door onto the roof
	behind: CFrame, -- the Creature's spot right behind the door, facing it (root)
	cue: Vector3, -- where the door's sounds and shakes come from (roof side, mid-height)
}

export type Sample = { position: Vector3 }

export type SmashInput = {
	smashNow: boolean, -- a loud noise after the first one stepped out
	firstOutAt: number?, -- when the first participant stepped out of the housing
	grace: number, -- ObjectiveConfig.graceFor(difficulty)
	activatedAt: number,
	now: number,
}

export type LedgeInput = {
	jumped: number, -- off the roof: in freefall, under a canopy or down below
	roofAlive: number, -- Alive participants who have not jumped
	lastLeftAt: number?, -- when the most recent jumper left the roof
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
	creatureRoot: () -> Vector3?,
	door: () -> Model?,
	doorState: (door: Model) -> Enums.DoorState,
	setDoor: (door: Model, state: Enums.DoorState, seconds: number?) -> boolean,
	oneShot: (kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg }, subject: Instance?) -> (),
	jump: (player: Player) -> Jump?,
	releaseHold: (player: Player) -> boolean,
	notify: (player: Player, key: string) -> (),
}

type SmashRun = { startAt: number, slammed: boolean, revealed: boolean, released: boolean }

local LEVEL: Enums.LevelId = "Level3_Roof"
local TOKEN = "L3_Roof"
local DOOR_ID = "RoofStairDoor"
local HOUSING_ROOM = "L3_RoofAccess"
local ROOF_SIDE_ROOM = "L3_Roof_East"
local TICK = 1 / GameConfig.ServerTickHz
local LEAD = GameConfig.OneShotLead
local OPEN_DELAY = 1.2 -- the wind takes the door this long after the first arrival in the housing
local OPEN_SECONDS = 1.4
local DOOR_CLEAR = 9 -- studs from the doorway everyone must be before it slams
local ARRIVAL_TIMEOUT = 75
local BEHIND_DOOR = 3 -- studs behind the door the Creature stands for the blows
local LEDGE_DELAY = 2 -- the Creature steps onto the ledge this long after the last jump
local LEDGE_INSET = 1.2 -- the Creature stands this far in from the edge
local ROOT_HEIGHT = CreatureConfig.Rig.HipHeight + CreatureConfig.Rig.RootSize.Y / 2
local EYE_HEIGHT = CreatureConfig.EyeHeightAboveRoot.Biped
local CHEST_HEIGHT = 1.2
local BIPED: Enums.PoseMode = "Biped"
local CHASE_STATE: Enums.MonsterState = "WallChase"
local PATROL_STATE: Enums.MonsterState = "Patrol"
local PARKED_STATE: Enums.MonsterState = "Dormant"
local TIMELINE_KIND: Enums.OneShotKind = "Timeline"
local RUN_KEY = "Hud.RoofRun"
local DOOR = Scenes.RoofDoor
local ROOF_ARGS = Scenes.RoofArgs
local ON_ROOF: { [string]: boolean } = { None = true, Packed = true }

local Level3 = {}

Level3.LevelId = LEVEL
Level3.Token = TOKEN
Level3.OpenDelay = OPEN_DELAY
Level3.DoorClear = DOOR_CLEAR
Level3.SmashTimeout = ObjectiveConfig.graceFor("Standard") -- the wait behind the door on Standard
Level3.ArrivalTimeout = ARRIVAL_TIMEOUT
Level3.LedgeDelay = LEDGE_DELAY
Level3.LedgeInset = LEDGE_INSET
Level3.RunKey = RUN_KEY

local escapedSignal: Signal.Signal<Player> = Signal.new()

-- (player) once per run when a jumper got away: the moment they are down below. MatchAndDataService takes that moment
-- as their escape time.
Level3.Escaped = escapedSignal

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

local function worldRect(origin: Vector3, r: LayoutSchema.Rect): Rect
	return { minX = origin.X + r.x, maxX = origin.X + r.x + r.w, minZ = origin.Z + r.z, maxZ = origin.Z + r.z + r.d }
end

local function inRect(rect: Rect, position: Vector3): boolean
	return position.X >= rect.minX and position.X <= rect.maxX and position.Z >= rect.minZ and position.Z <= rect.maxZ
end

-- The roof door of the housing `arrival` (a Stairwell_2_3 candidate; nil: the middle one) leads up to.
function Level3.roofDoor(layout: LayoutSchema.LevelLayout, arrival: WorldConfig.StairwellSpec?): LayoutSchema.Door?
	local housingId = if arrival then arrival.toRoom else HOUSING_ROOM
	for _, candidate in layout.doors do
		if candidate.kind == "RoofDoor" and table.find(candidate.rooms, housingId) and candidate.scriptedId then
			return candidate
		end
	end
	return nil
end

-- The ScriptedId of the roof door the run arrives behind (DoorService.Get on the roof).
function Level3.doorId(layout: LayoutSchema.LevelLayout?, arrival: WorldConfig.StairwellSpec?): string
	local door = if layout then Level3.roofDoor(layout, arrival) else nil
	return if door and door.scriptedId then door.scriptedId else DOOR_ID
end

-- Everything the level needs from the roof's blueprint (world positions), for a squad arriving by `arrival` (a
-- Stairwell_2_3 candidate; nil: the middle one).
function Level3.geometry(layout: LayoutSchema.LevelLayout, arrival: WorldConfig.StairwellSpec?): Geometry
	local origin = WorldConfig.levelOrigin(layout.id)
	local rooms = LayoutSchema.indexRooms(layout)
	local housingId = if arrival then arrival.toRoom else HOUSING_ROOM
	local housing = rooms[housingId]
	local roofSide = rooms[ROOF_SIDE_ROOM]
	assert(housing and roofSide, "the roof has no " .. housingId .. " / " .. ROOF_SIDE_ROOM)
	local door = Level3.roofDoor(layout, arrival)
	assert(door, "the roof has no roof door on " .. housingId)
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
function Level3.inside(position: Vector3, g: Geometry): boolean
	return inRect(g.housing, position) or inRect(g.tower, position)
end

-- Whether everyone is out on the roof and clear of the door (the door may slam), and whether anyone is out at all.
function Level3.squadOut(samples: { Sample }, g: Geometry): (boolean, boolean)
	local anyOut = false
	local allOut = #samples > 0
	for _, sample in samples do
		local inside = Level3.inside(sample.position, g)
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
function Level3.smashDue(input: SmashInput): boolean
	if input.smashNow then
		return true
	end
	local firstOut = input.firstOutAt
	if firstOut ~= nil and input.now >= firstOut + input.grace then
		return true
	end
	return input.now >= input.activatedAt + ARRIVAL_TIMEOUT
end

-- Whether the Creature steps onto the ledge now (see the header).
function Level3.ledgeReady(input: LedgeInput): boolean
	if input.jumped == 0 or input.roofAlive > 0 then
		return false
	end
	local lastLeft = input.lastLeftAt
	return lastLeft == nil or input.now >= lastLeft + LEDGE_DELAY
end

-- Where the Creature stands on the ledge: nearest where the squad left the roof (the average of `leftFrom`; the jump
-- gap when nobody did), LedgeInset in from the edge, facing out over them.
function Level3.revealPose(leftFrom: { Vector3 }): CFrame
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
function Level3.stareTarget<T>(jumpers: { { who: T, position: Vector3 } }, ledge: Vector3): T?
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
		creatureRoot = function(): Vector3?
			local model = MonsterAIService.GetCreature()
			local root = if model then model:FindFirstChild("HumanoidRootPart") else nil
			return if root and root:IsA("BasePart") then root.CFrame.Position else nil
		end,
		door = function(): Model?
			return DoorService.Get(LEVEL, Level3.doorId(Builder.getLayout(LEVEL), LevelDirector.entryFor(LEVEL)))
		end,
		doorState = DoorService.GetState,
		setDoor = DoorService.SetState,
		oneShot = LevelKit.oneShot,
		jump = ParachuteService.GetJump,
		releaseHold = ParachuteService.ReleaseHold,
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
local smashNow = false
local doorOpened = false
local smashRun: SmashRun? = nil
local ledgeAt: number? = nil -- when the Creature was staged on the ledge
local nextTickAt = -math.huge
local escaped: { [Player]: boolean } = {}

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
	local built = Level3.geometry(layout, arrival)
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
			Level3.inside(sample.position, g)
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
		-- it runs down someone it can see from the doorway; anyone out of sight is left to its senses
		local squad = deps.players()
		letGo(if seen(g.behind.Position, squad) then CHASE_STATE else PATROL_STATE)
		for _, player in squad do
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
	local _, anyOut = Level3.squadOut(samples, g)
	if anyOut and firstOutAt == nil then
		firstOutAt = now
	end
	if
		Level3.smashDue({
			smashNow = smashNow,
			firstOutAt = firstOutAt,
			grace = ObjectiveConfig.graceFor(difficulty),
			activatedAt = activatedAt,
			now = now,
		})
	then
		startSmash(now, g)
	end
end

--------------------------------------------------------------------------------
-- The ledge staging
--------------------------------------------------------------------------------

-- Puts the Creature on the ledge over the jumpers, shown, staring at the nearest. False while it cannot be taken.
local function stageLedge(now: number): boolean
	local h = handle or deps.acquire(TOKEN)
	if not h then
		return false
	end
	handle = h
	-- a door sequence still running is called off: nobody is left up there to chase
	schedule:Clear()
	phase = "Ledge"
	ledgeAt = now
	local leftFrom: { Vector3 } = {}
	local below: { { who: Player, position: Vector3 } } = {}
	for _, player in deps.players() do
		local jump = deps.jump(player)
		local from = if jump then jump.leftFrom else nil
		if jump and from and not ON_ROOF[jump.state] then
			table.insert(leftFrom, from)
			local root = deps.rootOf(player)
			if root then
				table.insert(below, { who = player, position = root })
			end
		end
	end
	local pose = Level3.revealPose(leftFrom)
	h:SetPose(BIPED)
	h:Teleport(pose)
	h:Face(pose.Position + pose.LookVector * 6)
	h:SetHidden(false)
	local target = Level3.stareTarget(below, pose.Position)
	if target then
		deps.stare(TOKEN, target)
	end
	log.info("the Creature stands on the ledge")
	return true
end

local function checkLedge(now: number, players: { Player })
	local jumped, roofAlive = 0, 0
	local lastLeft: number? = nil
	for _, player in players do
		local jump = deps.jump(player)
		local state = if jump then jump.state else "None"
		if not ON_ROOF[state] then
			jumped += 1
			local left = if jump then jump.leftAt else nil
			if left ~= nil and (lastLeft == nil or left > lastLeft) then
				lastLeft = left
			end
		elseif deps.lifeState(player) == "Alive" then
			roofAlive += 1
		end
	end
	if Level3.ledgeReady({ jumped = jumped, roofAlive = roofAlive, lastLeftAt = lastLeft, now = now }) then
		stageLedge(now)
	end
end

-- Landings: each jumper escapes the moment they are first seen down below, and their hold ends.
local function noteLandings(players: { Player })
	for _, player in players do
		if jumpState(player) == "Landed" and not escaped[player] then
			escape(player)
			deps.releaseHold(player)
		end
	end
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- One step at `now` (the Levels service runs it every Heartbeat; specs call it with a fake clock): scheduled beats on
-- time, the level's checks at the server tick rate.
function Level3.Step(now: number?)
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
	noteLandings(players)
	if phase == "Arrival" then
		ensureHeld(players)
		stepArrival(t, g, players)
	end
	if phase == "Arrival" or phase == "Smash" or phase == "Chase" then
		checkLedge(t, players)
	end
end

function Level3.GetPhase(): Phase
	return phase
end

function Level3.IsHolding(): boolean
	return handle ~= nil
end

function Level3.HasEscaped(player: Player): boolean
	return escaped[player] == true
end

function Level3.GetGeometry(): Geometry?
	return geo()
end

-- The door sequence of this run so far (nil before it started): whether the wind slammed the door, the Creature was
-- shown behind it and let go.
function Level3.GetSmash(): { startAt: number, slammed: boolean, revealed: boolean, released: boolean }?
	local run = smashRun
	if not run then
		return nil
	end
	return { startAt = run.startAt, slammed = run.slammed, revealed = run.revealed, released = run.released }
end

-- When the Creature was staged on the ledge; nil before it.
function Level3.GetLedgeAt(): number?
	return ledgeAt
end

-- Names of the beats still to come.
function Level3.Pending(): { string }
	return schedule:Pending()
end

-- A participant's High / Critical noise on the roof once someone has stepped out ends the wait behind the door.
function Level3.HeardNoise(event: Types.NoiseEvent)
	if not (active and phase == "Arrival" and firstOutAt ~= nil) or event.sourceUserId == nil then
		return
	end
	if event.levelId == LEVEL and (event.priority == "High" or event.priority == "Critical") then
		smashNow = true
	end
end

-- Starts the door sequence now (dev). False unless the squad is still arriving.
function Level3.Smash(): boolean
	local g = geo()
	if not (active and phase == "Arrival" and g) then
		return false
	end
	startSmash(deps.now(), g)
	return true
end

-- Stages the Creature on the ledge now (dev). False unless the level is live, someone has jumped, it is not on the
-- ledge yet and it can be taken.
function Level3.StageLedge(): boolean
	if not (active and (phase == "Arrival" or phase == "Smash" or phase == "Chase")) then
		return false
	end
	local anyone = false
	for _, player in deps.players() do
		if not ON_ROOF[jumpState(player)] then
			anyone = true
		end
	end
	return anyone and stageLedge(deps.now())
end

function Level3.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
end

--------------------------------------------------------------------------------
-- Level controller + lifecycle (driven by the Levels service)
--------------------------------------------------------------------------------

local function cancel(parkState: Enums.MonsterState?)
	schedule:Clear()
	letGo(parkState)
	smashRun = nil
end

-- LevelDirector: the squad is on the roof. The Creature is taken now, before the brain's own activation handling (which
-- brings it to the level's spawn in the housing, hidden), so it never starts a patrol here.
function Level3.Activate(_ctx: Types.LevelContext)
	active = true
	phase = "Arrival"
	nextTickAt = -math.huge
	activatedAt = deps.now()
	arrivedAt = nil
	firstOutAt = nil
	smashNow = false
	doorOpened = false
	smashRun = nil
	ledgeAt = nil
	if handle == nil then
		local h = deps.acquire(TOKEN)
		if h then
			handle = h
			h:SetHidden(true)
		end
	end
end

-- LevelDirector: the squad left the roof (a dev skip) or the run ended.
function Level3.Deactivate()
	active = false
	phase = "Idle"
	cancel(PARKED_STATE)
end

local controller: Types.LevelController = {
	LevelId = LEVEL,
	Activate = Level3.Activate,
	Deactivate = Level3.Deactivate,
}
Level3.Controller = controller

local function roofCommand(_player: Player, args: { string }): string?
	local action = string.lower(args[1] or "")
	if action == "smash" then
		return if Level3.Smash() then "the roof door sequence is playing" else "only while the squad is arriving"
	elseif action == "ledge" then
		return if Level3.StageLedge()
			then "the Creature is on the ledge"
			else "the ledge needs someone off the roof (chute give, then jump) and a free Creature, once"
	end
	return string.format(
		"roof: %s%s. usage: roof smash | ledge",
		phase,
		if handle then ", holding the Creature" else ""
	)
end

-- The roof's phases in which the Creature never teleports (docs/MONSTER.md 7.2): the door, the chase, the ledge.
local NO_TELEPORT: { [string]: boolean } = { Smash = true, Chase = true, Ledge = true }

function Level3.Init()
	DevToolsService.Register("roof", "roof [smash|ledge]: the roof door sequence or the ledge staging now", roofCommand)
	MonsterAIService.RegisterTeleportBlock(function(): boolean
		return active and NO_TELEPORT[phase] == true
	end)
	NoiseAndDirectorService.NoiseEmitted:Connect(Level3.HeardNoise)
end

local function resetState()
	active = false
	phase = "Idle"
	arrivedAt = nil
	firstOutAt = nil
	smashNow = false
	doorOpened = false
	smashRun = nil
	ledgeAt = nil
	nextTickAt = -math.huge
	table.clear(escaped)
end

function Level3.BeginRun(ctx: Types.RunContext)
	cancel(nil)
	resetState()
	difficulty = ctx.difficulty
end

function Level3.EndRun()
	cancel(PARKED_STATE)
	resetState()
end

return table.freeze(Level3)
