--!strict
-- Brain: the pure core of the Creature's mind ("the Tall Man", docs/MONSTER.md 6; the website's
-- web/src/creature/brain.js), shared by MonsterAIService and its state modules.
--
--   * decide(summary): the transition table (docs/MONSTER.md 6.1, first match wins): Scripted > Stunned > Dormant (its
--     level is not awake yet) > hold still while a catch, a grab or a ReachIn plays > hold while it fades out / in (a
--     warp) > a stun just ended: Patrol (withdrawing) > retreating in the water after a grab: AquaticStalk > a chase
--     MaxChase seconds in, or one the pacing calls off (catch cooldown, Relax): it gives up and fades out (Patrol) > no
--     hunting allowed: Patrol (withdrawing from a HidingResponse) > the Chase (WallChase): it saw its quarry hide:
--     HidingResponse; in sight (or stared at): on; line of sight lost for ChaseLost seconds, or the last seen point
--     reached: Search > HidingResponse holds until its hider is out or taken (then WallChase on whoever it sees, else
--     Search) > it saw someone hide: HidingResponse > a 1 s stare: WallChase > someone in sight: WallChase (AquaticStalk
--     when it swims and they swim: a swimmer is only ever taken by the telegraphed lunge) > a swimmer on the pool level:
--     AquaticStalk > AquaticStalk ends when the water is calm > a teleport runs to its end (warning, FadeIn, stare,
--     stalk) > a noise outside InvestigateNoise and Search: InvestigateNoise > an investigation re-targets on a noise at
--     least as loud, else ends (Patrol) > a Search breaks off for a High or Critical noise, else ends (Patrol) > a
--     teleport that is due: Teleport > Patrol (the Stalk).
--   * catchKind(check): whether a catch may happen now (reach, the same floor, a clear line eye to eye AND chest to
--     chest: never through a wall). The Creature never enters a duct: there is no Vent catch.
--   * levelInfo(layout): patrol loops (the layout's PatrolWaypoint anchors by "<prefix>_WP_<loop>_<NN>", else loops
--     derived from the level's rooms), rooms and the open doorways between them, pool basins and the CreatureSpawn (one
--     in a room outside the level's main walkable component does not count).
-- The runtime Context type the states work through lives here too, so states never require MonsterAIService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local PacingDirector = require(ServerScriptService.Services.Core.NoiseAndDirectorService.PacingDirector)

local CreatureBody = require(script.Parent.CreatureBody)
local FloorNav = require(script.Parent.FloorNav)
local Locomotion = require(script.Parent.Locomotion)
local Perception = require(script.Parent.Perception)

export type Summary = {
	state: Enums.MonsterState,
	elapsed: number, -- seconds in the state
	scripted: boolean, -- a cutscene holds the Creature
	stunned: boolean, -- stun time left
	awake: boolean, -- its level is active and the wake delay has run
	catching: boolean, -- a catch, a grab or a ReachIn is playing
	warping: boolean, -- a FadeOut / FadeIn relocation runs
	canHunt: boolean, -- pacing allows chases, investigations and catches
	sees: boolean, -- somebody it may chase is in sight
	stared: boolean, -- somebody held a stare on it for the full second
	hidingWatch: boolean, -- it saw somebody climb into a hiding spot
	heard: number, -- rank of the loudest noise heard this tick (0 = none)
	investigating: number, -- rank of the noise under investigation (0 = none)
	chaseSeconds: number,
	lostSeconds: number, -- seconds since the chase last saw its quarry
	maxChase: number,
	chaseLost: number,
	swimmer: boolean, -- pool level, a swimmer sensed recently
	inWater: boolean?, -- the Creature swims
	retreating: boolean?, -- it retreats to the far end of the water after a grab (Level 4 fairness)
	teleportDue: boolean,
	stateDone: boolean, -- the state finished its job
}

export type Decision = { state: Enums.MonsterState, reason: string, reposition: boolean, giveUp: boolean }

export type CatchCheck = {
	horizontal: number, -- root to root
	vertical: number,
	reach: number,
	targetInVent: boolean,
	lineClear: boolean, -- eye to eye
	bodyClear: boolean, -- chest to chest
	playing: boolean,
	hiding: boolean,
	canHunt: boolean,
	busy: boolean, -- a catch is already playing
	hidden: boolean, -- the Creature is hidden
	stunned: boolean,
	warping: boolean?,
	creatureInWater: boolean?, -- in or from the water the pool's telegraphed grab is the only catch
	targetSwimming: boolean?,
}

export type Waypoint = { id: string, loop: string, order: number, position: Vector3, zoneId: string }

export type Loop = { id: string, waypoints: { Waypoint }, zones: { [string]: boolean }, centre: Vector3 }

export type Room = {
	id: string,
	kind: Enums.RoomKind,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	floorY: number,
	height: number,
	centre: Vector3, -- floor level
}

export type LevelInfo = {
	levelId: Enums.LevelId,
	origin: Vector3,
	loops: { Loop },
	waypoints: { Waypoint },
	derived: boolean, -- the loops were derived from the rooms (no PatrolWaypoints)
	rooms: { [string]: Room },
	roomList: { Room },
	neighbours: { [string]: { string } }, -- rooms joined by an open doorway
	basins: { Locomotion.Basin },
	spawn: CFrame?, -- root CFrame at the CreatureSpawn anchor
}

export type HeardNoise = {
	position: Vector3, -- where the Creature believes it came from
	rank: number,
	priority: Enums.NoisePriority,
	medium: Enums.NoiseMedium,
	kind: Enums.NoiseKind,
	sourceUserId: number?,
	zoneId: string?,
	strength: number,
	at: number,
}

export type Memory = { player: Player, position: Vector3, at: number }

export type Investigation = { position: Vector3, rank: number, at: number }

export type HeardZone = { at: number, rank: number, position: Vector3 }

-- A hiding spot as the brain knows it: the model, its kind and its front (the ExitAnchor: floor level, LookVector out
-- of the spot).
export type HideSpot = { id: Instance, kind: Enums.HideKind, front: CFrame }

-- The watch on a hiding spot it saw someone climb into.
export type HideWatch = { player: Player, spot: Instance, front: CFrame, since: number }

-- A planned teleport: the target, where it forms (a root CFrame facing them), which side of them, its walk.
export type TeleportPlan = { target: Player, spot: CFrame, side: string, walk: number }

export type Context = {
	creature: Model,
	body: CreatureBody.Body,
	mover: Locomotion.Mover,
	level: LevelInfo?,
	difficulty: Enums.Difficulty,
	random: Random,
	now: () -> number,

	-- this tick's senses (refreshed before the state updates)
	sightings: { Perception.Sighting },
	heard: HeardNoise?,
	heardZones: { [string]: HeardZone }, -- rooms where it heard something lately
	target: Player?,
	memory: Memory?,
	phase: PacingDirector.PacingPhase,
	canHunt: boolean,

	-- hand-offs between the brain and the states
	investigation: Investigation?,
	searchFrom: Vector3?,
	hiding: HideWatch?,
	teleportPlan: TeleportPlan?,
	reposition: boolean,
	stateDone: boolean,
	stunFrom: Vector3?,

	-- bound by MonsterAIService
	speedOf: (state: Enums.MonsterState) -> number,
	setTarget: (player: Player?) -> (),
	catchKind: (player: Player) -> Enums.JumpscareKind?,
	tryCatch: (player: Player, kind: Enums.JumpscareKind) -> boolean,
	reachIn: (player: Player, spot: Instance) -> (),
	visible: (point: Vector3) -> boolean, -- some player could see the Creature standing there
	reachable: () -> ((point: Vector3) -> boolean)?, -- which points it can walk to from where it stands
	repositionPoint: (minDistance: number, maxDistance: number) -> Vector3?,
	playerPositions: () -> { Vector3 },
	lockerInspector: () -> Types.LockerInspector?,
	poolGrabber: () -> Types.PoolGrabber?,
	grabArmed: (player: Player) -> boolean, -- their splashing crossed the grab threshold lately
	setGrabbed: (player: Player?) -> (),
	inVent: (player: Player) -> boolean,
	swimming: (player: Player) -> boolean,
	playing: (player: Player) -> boolean, -- hunted and playing
	isHiding: (player: Player) -> boolean,
	hideSpotOf: (player: Player) -> Instance?,
	hideSpotsNear: (point: Vector3, radius: number) -> { HideSpot },
	hideSpotOccupant: (spot: Instance) -> Player?,
	hideSpotFront: (spot: Instance) -> CFrame?,
	pulledOut: (player: Player) -> boolean, -- a teammate pulled them out of their hiding spot just now
	bodyClear: (player: Player) -> boolean, -- chest to chest, never through a wall
	telegraph: ((origin: Vector3, seconds: number) -> ())?, -- a lunge is coming from `origin` (Level 4 fairness)
	poolRetreat: (() -> Vector3?)?, -- while it retreats after a grab: the far end of the water
	rootOf: (player: Player) -> Vector3?,
	floorPointNear: (position: Vector3) -> Vector3,
	lineClear: (from: Vector3, to: Vector3) -> boolean, -- a sight line (Default group, characters excluded)
	setLookAway: (direction: Vector3?) -> (),
	lookAwayDirection: (front: CFrame) -> Vector3,
	grunt: () -> (),
	startTeleport: (plan: TeleportPlan) -> boolean,
	warping: () -> boolean,
	creatureEye: () -> Vector3,
}

export type StateModule = {
	Name: Enums.MonsterState,
	enter: (ctx: Context, from: Enums.MonsterState) -> (),
	update: (ctx: Context, dt: number) -> (),
	exit: (ctx: Context, to: Enums.MonsterState) -> (),
}

local SENSES = CreatureConfig.Senses
local WAYPOINT_PATTERN = "_WP_(.+)_(%d+)$"
local PASSABLE_DOORS: { [string]: boolean } = { Doorway = true, Door = true, Ajar = true }
local WALKABLE_DOORS: { [string]: boolean } =
	{ Doorway = true, Door = true, Ajar = true, RoofDoor = true, Gate = true, Airlock = true }
local CHASES: { [string]: boolean } = { WallChase = true }
local SEARCHES: { [string]: boolean } = { InvestigateNoise = true, Search = true }
local EXACT_RANK = 3
-- rooms the derived patrol never walks into (the stair vestibules, ducts, the stairwells, crawlways)
local NO_PATROL: { [string]: boolean } = { Airlock = true, Chase = true, Stairwell = true, Crawlway = true }
local NO_ROOM: { [string]: boolean } = { Solid = true }
local DERIVED_SPACING = 30
local DERIVED_INSET = 3
local DERIVED_LOOP = 6
local FREE_CLEARANCE = 2.5

local Brain = {}

Brain.MemorySeconds = SENSES.MemorySeconds
Brain.CatchVertical = SENSES.CatchVertical

function Brain.isChase(state: string): boolean
	return CHASES[state] == true
end

local function difficultySpec(difficulty: Enums.Difficulty): DifficultyConfig.DifficultySpec
	return if difficulty == "Nightmare" then DifficultyConfig.Nightmare else DifficultyConfig.Standard
end

Brain.difficultySpec = difficultySpec

--------------------------------------------------------------------------------
-- Decisions
--------------------------------------------------------------------------------

local function go(state: Enums.MonsterState, reason: string, reposition: boolean?, giveUp: boolean?): Decision
	return { state = state, reason = reason, reposition = reposition == true, giveUp = giveUp == true }
end

function Brain.decide(s: Summary): Decision
	local state: Enums.MonsterState = s.state
	if s.scripted then
		return go("Scripted", "scripted")
	end
	if s.stunned then
		return go("Stunned", "stunned")
	end
	if not s.awake then
		return go("Dormant", "asleep")
	end
	if s.catching then
		return go(state, "catching")
	end
	if s.warping then
		return go(state, "fading")
	end
	if state == "Stunned" then
		return go("Patrol", "recovered", true)
	end
	if s.retreating and s.inWater then
		return go("AquaticStalk", "retreating")
	end
	-- a chase that runs out (MaxChase) or is called off (the pacing's breather) ends the same way: it fades away
	if state == "WallChase" and (s.chaseSeconds >= s.maxChase or not s.canHunt) then
		return go("Patrol", if s.canHunt then "gave up" else "breather", true, true)
	end
	if not s.canHunt then
		return go("Patrol", "breather", state == "HidingResponse")
	end
	if state == "WallChase" then
		if s.hidingWatch then
			return go("HidingResponse", "saw them hide")
		end
		if s.sees or s.stared then
			return go("WallChase", "in sight")
		end
		if s.lostSeconds >= s.chaseLost or s.stateDone then
			return go("Search", "lost sight")
		end
		return go("WallChase", "tracking")
	end
	if state == "HidingResponse" then
		if not s.stateDone then
			return go("HidingResponse", "waiting")
		end
		if s.sees or s.stared then
			return go("WallChase", "out of hiding")
		end
		return go("Search", "slipped away")
	end
	if s.hidingWatch then
		return go("HidingResponse", "saw them hide")
	end
	if s.stared then
		return go("WallChase", "stared at")
	end
	if s.sees then
		if s.swimmer and s.inWater then
			-- a swimmer is only ever taken by the telegraphed lunge
			return go("AquaticStalk", "swimmer in sight")
		end
		return go("WallChase", "seen")
	end
	if s.swimmer then
		return go("AquaticStalk", "swimmer")
	end
	if state == "AquaticStalk" then
		return go("Patrol", "water calm")
	end
	if state == "Teleport" and not s.stateDone then
		return go("Teleport", "teleporting")
	end
	if s.heard > 0 and not SEARCHES[state] then
		return go("InvestigateNoise", "heard")
	end
	if state == "InvestigateNoise" then
		if s.heard >= s.investigating and s.heard > 0 then
			return go("InvestigateNoise", "heard")
		end
		if s.stateDone then
			return go("Patrol", "nothing found")
		end
		return go("InvestigateNoise", "searching")
	end
	if state == "Search" then
		if s.heard >= EXACT_RANK then
			return go("InvestigateNoise", "heard")
		end
		if s.stateDone then
			return go("Patrol", "search over")
		end
		return go("Search", "searching")
	end
	if s.teleportDue then
		return go("Teleport", "teleport")
	end
	return go("Patrol", "patrolling")
end

--------------------------------------------------------------------------------
-- Catches
--------------------------------------------------------------------------------

function Brain.catchKind(check: CatchCheck): Enums.JumpscareKind?
	if check.busy or not check.canHunt or check.hidden or check.stunned or check.warping then
		return nil
	end
	if check.creatureInWater or check.targetSwimming then
		return nil -- in the water the pool's telegraphed grab is the only catch
	end
	if not check.playing or check.hiding or check.targetInVent then
		return nil
	end
	-- never through a wall: the eyes and the bodies both see each other
	if not check.lineClear or not check.bodyClear then
		return nil
	end
	if check.horizontal <= check.reach and check.vertical <= SENSES.CatchVertical then
		return "Hallway"
	end
	return nil
end

-- The speed of a state on a difficulty (Scripted moves at its own pace; nothing else outruns a sprinter).
function Brain.speedFor(state: string, difficulty: Enums.Difficulty): number
	local base = CreatureConfig.Speeds[state] or CreatureConfig.Speeds.Patrol
	if state == "Scripted" then
		return base
	end
	return math.min(CreatureConfig.SpeedCap, base * difficultySpec(difficulty).creatureSpeedMultiplier)
end

--------------------------------------------------------------------------------
-- Level knowledge
--------------------------------------------------------------------------------

local function finishLoops(byLoop: { [string]: { Waypoint } }): { Loop }
	local loops: { Loop } = {}
	for id, list in byLoop do
		table.sort(list, function(a: Waypoint, b: Waypoint): boolean
			return a.order < b.order
		end)
		local zones: { [string]: boolean } = {}
		local sum = Vector3.zero
		for _, waypoint in list do
			zones[waypoint.zoneId] = true
			sum += waypoint.position
		end
		table.insert(loops, { id = id, waypoints = list, zones = zones, centre = sum / #list })
	end
	table.sort(loops, function(a: Loop, b: Loop): boolean
		return a.id < b.id
	end)
	return loops
end

-- Patrol loops from PatrolWaypoint anchors (any order in), each loop's waypoints in walking order, loops by id.
-- `place` turns an anchor into its world position.
function Brain.patrolLoops(anchors: { LayoutSchema.Anchor }, place: (LayoutSchema.Anchor) -> Vector3): { Loop }
	local byLoop: { [string]: { Waypoint } } = {}
	for _, anchor in anchors do
		if anchor.kind ~= "PatrolWaypoint" then
			continue
		end
		local loop, order = string.match(anchor.id, WAYPOINT_PATTERN)
		local number = if order then tonumber(order) else nil
		if not (loop and number) then
			continue
		end
		local list = byLoop[loop]
		if not list then
			list = {}
			byLoop[loop] = list
		end
		table.insert(
			list,
			{ id = anchor.id, loop = loop, order = number, position = place(anchor), zoneId = anchor.room }
		)
	end
	return finishLoops(byLoop)
end

export type Obstacle = FloorNav.Obstacle

local function insideAny(obstacles: { Obstacle }, x: number, z: number, grow: number): boolean
	for _, o in obstacles do
		if x >= o.minX - grow and x <= o.maxX + grow and z >= o.minZ - grow and z <= o.maxZ + grow then
			return true
		end
	end
	return false
end

-- The point of `room` nearest x, z (inset from its walls) that no obstacle footprint covers, or nil.
function Brain.freePointIn(room: Room, obstacles: { Obstacle }, x: number, z: number, inset: number?): Vector2?
	local i = inset or DERIVED_INSET
	local minX, maxX, minZ, maxZ = room.minX + i, room.maxX - i, room.minZ + i, room.maxZ - i
	if minX > maxX or minZ > maxZ then
		return nil
	end
	local cx = math.clamp(x, minX, maxX)
	local cz = math.clamp(z, minZ, maxZ)
	if not insideAny(obstacles, cx, cz, FREE_CLEARANCE) then
		return Vector2.new(cx, cz)
	end
	for r = 2, 30, 2 do
		for k = 0, 15 do
			local a = k / 16 * math.pi * 2
			local px, pz = cx + math.cos(a) * r, cz + math.sin(a) * r
			if px < minX or px > maxX or pz < minZ or pz > maxZ then
				continue
			end
			if not insideAny(obstacles, px, pz, FREE_CLEARANCE) then
				return Vector2.new(px, pz)
			end
		end
	end
	return nil
end

-- Patrol loops for a level without PatrolWaypoints: points over its rooms (one at the free spot nearest each room's
-- centre, a grid every DERIVED_SPACING studs in the big ones), chained nearest-first into loops of DERIVED_LOOP
-- points. Deterministic.
function Brain.derivedLoops(rooms: { Room }, obstacles: { Obstacle }): { Loop }
	type Point = { room: string, position: Vector3 }
	local points: { Point } = {}
	for _, room in rooms do
		if NO_PATROL[room.kind] then
			continue
		end
		local w, d = room.maxX - room.minX, room.maxZ - room.minZ
		local nx = math.max(1, math.floor(w / DERIVED_SPACING + 0.5))
		local nz = math.max(1, math.floor(d / DERIVED_SPACING + 0.5))
		for i = 0, nx - 1 do
			for j = 0, nz - 1 do
				local x = room.minX + w * (i + 0.5) / nx
				local z = room.minZ + d * (j + 0.5) / nz
				local free = Brain.freePointIn(room, obstacles, x, z)
				if free then
					table.insert(points, { room = room.id, position = Vector3.new(free.X, room.floorY, free.Y) })
				end
			end
		end
	end
	table.sort(points, function(a: Point, b: Point): boolean
		if a.position.X ~= b.position.X then
			return a.position.X < b.position.X
		end
		return a.position.Z < b.position.Z
	end)
	local byLoop: { [string]: { Waypoint } } = {}
	local n = 0
	while #points > 0 do
		local chain = { table.remove(points, 1) :: Point }
		while #chain < DERIVED_LOOP and #points > 0 do
			local last = chain[#chain].position
			local best = 1
			for i = 2, #points do
				if (points[i].position - last).Magnitude < (points[best].position - last).Magnitude then
					best = i
				end
			end
			table.insert(chain, table.remove(points, best) :: Point)
		end
		n += 1
		local id = string.format("Derived%02d", n)
		local list: { Waypoint } = {}
		for i, p in chain do
			table.insert(list, { id = id .. "_" .. i, loop = id, order = i, position = p.position, zoneId = p.room })
		end
		byLoop[id] = list
	end
	return finishLoops(byLoop)
end

-- The rooms of the level's main walkable component (the largest set joined by doorways, doors, gates and airlocks):
-- a room boarded shut or reached only through a duct or a crawlway is left out.
function Brain.mainRooms(layout: LayoutSchema.LevelLayout): { [string]: boolean }
	local links: { [string]: { string } } = {}
	local ids: { string } = {}
	for _, room in layout.rooms do
		if room.kind ~= "Chase" and room.kind ~= "Crawlway" and room.kind ~= "Solid" then
			links[room.id] = {}
			table.insert(ids, room.id)
		end
	end
	for _, door in layout.doors do
		if not WALKABLE_DOORS[door.kind] or LayoutSchema.doorCrawlOnly(layout, door) then
			continue
		end
		local a, b = door.rooms[1], door.rooms[2]
		if links[a] and links[b] then
			table.insert(links[a], b)
			table.insert(links[b], a)
		end
	end
	local best: { [string]: boolean } = {}
	local bestSize = 0
	local seen: { [string]: boolean } = {}
	for _, id in ids do
		if seen[id] then
			continue
		end
		local part: { [string]: boolean } = { [id] = true }
		local size = 1
		local queue = { id }
		seen[id] = true
		while #queue > 0 do
			local current = table.remove(queue, 1) :: string
			for _, nextId in links[current] do
				if not seen[nextId] then
					seen[nextId] = true
					part[nextId] = true
					size += 1
					table.insert(queue, nextId)
				end
			end
		end
		if size > bestSize then
			best, bestSize = part, size
		end
	end
	return best
end

local function worldCFrame(levelId: string, anchor: LayoutSchema.Anchor): CFrame
	return CFrame.new(WorldConfig.levelOrigin(levelId) + anchor.pos) * CFrame.Angles(0, math.rad(anchor.yaw or 0), 0)
end

function Brain.levelInfo(layout: LayoutSchema.LevelLayout): LevelInfo?
	local levelId = layout.id
	if not Enums.has(Enums.LevelId, levelId) then
		return nil
	end
	local id = levelId :: Enums.LevelId
	local origin = WorldConfig.levelOrigin(id)
	local rooms: { [string]: Room } = {}
	local roomList: { Room } = {}
	local roomRects: { [string]: LayoutSchema.Rect } = {}
	for _, room in layout.rooms do
		if NO_ROOM[room.kind] then
			continue
		end
		local r = room.rect
		local entry: Room = {
			id = room.id,
			kind = room.kind,
			minX = origin.X + r.x,
			maxX = origin.X + r.x + r.w,
			minZ = origin.Z + r.z,
			maxZ = origin.Z + r.z + r.d,
			floorY = origin.Y,
			height = LayoutSchema.roomHeight(layout, room),
			centre = origin + Vector3.new(r.x + r.w / 2, 0, r.z + r.d / 2),
		}
		rooms[room.id] = entry
		roomRects[room.id] = r
		table.insert(roomList, entry)
	end
	local reachable = Brain.mainRooms(layout)
	local loops = Brain.patrolLoops(layout.anchors, function(anchor: LayoutSchema.Anchor): Vector3
		return worldCFrame(id, anchor).Position
	end)
	local derived = false
	if #loops == 0 then
		local walkable: { Room } = {}
		for _, room in roomList do
			if room.kind ~= "Pool" and reachable[room.id] then
				table.insert(walkable, room)
			end
		end
		loops = Brain.derivedLoops(walkable, FloorNav.levelObstacles(layout, origin))
		derived = #loops > 0
	end
	local waypoints: { Waypoint } = {}
	for _, loop in loops do
		for _, waypoint in loop.waypoints do
			table.insert(waypoints, waypoint)
		end
	end
	local neighbours: { [string]: { string } } = {}
	for _, door in layout.doors do
		if not PASSABLE_DOORS[door.kind] then
			continue
		end
		local a, b = door.rooms[1], door.rooms[2]
		if not (rooms[a] and rooms[b]) then
			continue
		end
		for _, pair in { { a, b }, { b, a } } do
			local list = neighbours[pair[1]]
			if not list then
				list = {}
				neighbours[pair[1]] = list
			end
			if table.find(list, pair[2]) == nil then
				table.insert(list, pair[2])
			end
		end
	end
	local basins: { Locomotion.Basin } = {}
	for _, basin in layout.basins or {} :: { LayoutSchema.Basin } do
		local room = roomRects[basin.room] or basin.rect
		local made = Locomotion.makeBasin(basin.id, origin, basin.rect, room, basin.waterLevel, basin.depth)
		-- Level 4 fairness: the Creature enters and leaves the water only by fading out and in, out of sight
		made.fadeOnly = CreatureConfig.Water.FadeOnly
		table.insert(basins, made)
	end
	-- its CreatureSpawn (one in a room it could never walk out of does not count: the first waypoint instead)
	local spawn: CFrame? = nil
	local anyReachable = next(reachable) ~= nil
	for _, anchor in layout.anchors do
		if anchor.kind == "CreatureSpawn" and (not anyReachable or reachable[anchor.room]) then
			spawn = worldCFrame(id, anchor)
			break
		end
	end
	return {
		levelId = id :: Enums.LevelId,
		origin = origin,
		loops = loops,
		waypoints = waypoints,
		derived = derived,
		rooms = rooms,
		roomList = roomList,
		neighbours = neighbours,
		basins = basins,
		spawn = spawn,
	}
end

-- The room `position` stands in (a real room before a service chase; nil outside every room of the level).
function Brain.roomAt(info: LevelInfo, position: Vector3): Room?
	local chase: Room? = nil
	for _, room in info.roomList do
		if
			position.X >= room.minX
			and position.X <= room.maxX
			and position.Z >= room.minZ
			and position.Z <= room.maxZ
			and position.Y >= room.floorY - 40
			and position.Y <= room.floorY + room.height + 2
		then
			if room.kind ~= "Chase" then
				return room
			end
			chase = room
		end
	end
	return chase
end

return table.freeze(Brain)
