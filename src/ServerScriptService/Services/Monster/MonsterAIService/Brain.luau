--!strict
-- Brain: the pure core of the Creature's mind, shared by MonsterAIService and its state modules.
--
--   * decide(summary): the state machine's transition table. A Summary is what the senses and the pacing said this
--     tick (sightings, noises, memory, cooldowns) plus what the current state reported; the Decision names the state
--     to be in and whether it should first withdraw out of everyone's sight. Priorities, highest first:
--       Scripted (a cutscene holds the Creature) > Stunned > Dormant (its level is not awake yet) > hold still while a
--       catch plays > a stun just ended: Patrol (withdraw) > retreating in the water after a grab: AquaticStalk (to the
--       far end, no lunges) > no hunting allowed (catch cooldown, airlock grace, Relax):
--       Patrol, withdrawing from a chase > a chase that ran too long: Patrol (withdraw) > a crawler gave itself away
--       (seen climbing in, heard scurrying or kicking in the ducts, spotted through a grate): VentChase > VentChase
--       continues until it is done (out of the ducts or no way in), then WallChase if someone is in sight, else
--       InvestigateNoise > someone in sight: WallChase (VentChase when both are in the ducts; AquaticStalk when it swims
--       and they swim: a swimmer is only ever taken by the telegraphed lunge) > a swimmer on the pool
--       level: AquaticStalk > a lost chase is followed to the last known position for MemorySeconds, then searched
--       (InvestigateNoise) > AquaticStalk ends when the water is calm > a noise at least as loud as the one being
--       investigated: InvestigateNoise > an investigation that found nothing: Patrol.
--   * catchKind(check): whether a catch may happen now and which jumpscare it is (Hallway on floors, Vent in the
--     ducts). Never through walls (the line must be clear), never while the Creature is hidden or stunned, never during
--     a cooldown, never at a player hiding in a locker (lockers go through the LockerInspector hook).
--   * levelInfo(layout): what the Creature knows about a level from its blueprint: patrol loops (PatrolWaypoint
--     anchors "<prefix>_WP_<loop>_<NN>": waypoint i leads to i + 1 and the last back to the first), rooms and the
--     doorways between them, pool basins and the CreatureSpawn.
-- The runtime Context type the states work through lives here too, so states never require MonsterAIService.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Types = require(ReplicatedStorage.Shared.Types)
local VentGraph = require(ReplicatedStorage.Shared.Vents.VentGraph)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local PacingDirector = require(ServerScriptService.Services.Core.NoiseAndDirectorService.PacingDirector)

local CreatureBody = require(script.Parent.CreatureBody)
local Locomotion = require(script.Parent.Locomotion)
local Perception = require(script.Parent.Perception)

export type Summary = {
	state: Enums.MonsterState,
	elapsed: number, -- seconds in the state
	scripted: boolean, -- a cutscene holds the Creature
	stunned: boolean, -- stun time left
	awake: boolean, -- its level is active and the wake delay has run
	catching: boolean, -- a catch sequence is playing
	canHunt: boolean, -- pacing allows chases, investigations and catches
	inVent: boolean, -- the Creature is in a duct
	sees: boolean, -- somebody is in sight
	seesInVent: boolean, -- the best sighting is a crawler (only seen from inside a duct)
	ventQuarry: boolean, -- a crawler gave itself away
	heard: number, -- rank of the loudest noise heard this tick (0 = none)
	investigating: number, -- rank of the noise under investigation (0 = none)
	memoryAge: number?, -- seconds since the target was last seen or heard
	breakChase: boolean, -- the chase has run too long
	swimmer: boolean, -- pool level, a swimmer sensed recently
	inWater: boolean?, -- the Creature swims
	retreating: boolean?, -- it retreats to the far end of the water after a grab (Level 4 fairness)
	stateDone: boolean, -- the state finished its job
}

export type Decision = { state: Enums.MonsterState, reason: string, reposition: boolean }

export type CatchCheck = {
	horizontal: number, -- root to root
	vertical: number,
	distance: number, -- 3D, root to root
	creatureInVent: boolean,
	targetInVent: boolean,
	lineClear: boolean,
	playing: boolean,
	hiding: boolean,
	canHunt: boolean,
	busy: boolean, -- a catch is already playing
	hidden: boolean, -- the Creature is hidden
	stunned: boolean,
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

export type Context = {
	creature: Model,
	body: CreatureBody.Body,
	mover: Locomotion.Mover,
	level: LevelInfo?,
	graph: VentGraph.Graph?,
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
	reposition: boolean,
	stateDone: boolean,
	ventBlocked: boolean, -- VentChase found no way in
	stunFrom: Vector3?,

	-- bound by MonsterAIService
	speedOf: (state: Enums.MonsterState) -> number,
	setTarget: (player: Player?) -> (),
	catchKind: (player: Player) -> Enums.JumpscareKind?,
	tryCatch: (player: Player, kind: Enums.JumpscareKind) -> boolean,
	visible: (point: Vector3) -> boolean, -- some player could see the Creature standing there
	repositionPoint: (minDistance: number, maxDistance: number) -> Vector3?,
	playerPositions: () -> { Vector3 },
	lockerInspector: () -> Types.LockerInspector?,
	poolGrabber: () -> Types.PoolGrabber?,
	noteSpotted: (player: Player) -> (), -- seen crawling in a duct (through a grate)
	grabArmed: (player: Player) -> boolean, -- their splashing crossed the grab threshold lately
	setGrabbed: (player: Player?) -> (),
	inVent: (player: Player) -> boolean,
	railPointOf: (player: Player) -> VentGraph.RailPoint?,
	exitGrateOf: (player: Player) -> string?, -- the grate they last crawled out through
	ventOccupants: () -> { Player },
	grateState: (grateId: string) -> Enums.GrateState,
	standPoint: (grate: VentGraph.Grate) -> CFrame,
	swimming: (player: Player) -> boolean,
	telegraph: ((origin: Vector3, seconds: number) -> ())?, -- a lunge is coming from `origin` (Level 4 fairness)
	poolRetreat: (() -> Vector3?)?, -- while it retreats after a grab: the far end of the water
	rootOf: (player: Player) -> Vector3?,
	lineClear: (from: Vector3, to: Vector3) -> boolean, -- a sight line (Default group, characters excluded)
}

export type StateModule = {
	Name: Enums.MonsterState,
	enter: (ctx: Context, from: Enums.MonsterState) -> (),
	update: (ctx: Context, dt: number) -> (),
	exit: (ctx: Context, to: Enums.MonsterState) -> (),
}

local SENSES = CreatureConfig.Senses
local CATCH_VERTICAL = 5 -- a hallway catch needs both on the same floor
local WAYPOINT_PATTERN = "_WP_(.+)_(%d+)$"
local PASSABLE_DOORS: { [string]: boolean } = { Doorway = true, Door = true, Ajar = true }
local CHASES: { [string]: boolean } = { WallChase = true, VentChase = true }

local Brain = {}

Brain.MemorySeconds = SENSES.MemorySeconds
Brain.CatchVertical = CATCH_VERTICAL

function Brain.isChase(state: string): boolean
	return CHASES[state] == true
end

--------------------------------------------------------------------------------
-- Decisions
--------------------------------------------------------------------------------

local function go(state: Enums.MonsterState, reason: string, reposition: boolean?): Decision
	return { state = state, reason = reason, reposition = reposition == true }
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
		return go(s.state, "catching")
	end
	if state == "Stunned" then
		return go("Patrol", "recovered", true)
	end
	if s.retreating and s.inWater then
		return go("AquaticStalk", "retreating")
	end
	if not s.canHunt then
		return go("Patrol", "breather", CHASES[state] == true)
	end
	if CHASES[state] and s.breakChase then
		return go("Patrol", "chase ran too long", true)
	end
	if s.ventQuarry and state ~= "VentChase" then
		return go("VentChase", "crawler")
	end
	if state == "VentChase" then
		if not s.stateDone then
			return go("VentChase", "crawling")
		end
		if s.sees and not s.seesInVent then
			return go("WallChase", "out of the ducts")
		end
		return go("InvestigateNoise", "lost in the ducts")
	end
	if s.sees then
		if s.seesInVent then
			return go("VentChase", "seen in the ducts")
		end
		if s.swimmer and s.inWater then
			-- a swimmer is only ever taken by the telegraphed lunge
			return go("AquaticStalk", "swimmer in sight")
		end
		return go("WallChase", "seen")
	end
	if s.swimmer then
		return go("AquaticStalk", "swimmer")
	end
	if state == "WallChase" then
		local age = s.memoryAge
		if age ~= nil and age <= SENSES.MemorySeconds and not s.stateDone then
			return go("WallChase", "tracking")
		end
		return go("InvestigateNoise", "lost sight")
	end
	if state == "AquaticStalk" then
		return go("Patrol", "water calm")
	end
	if s.heard > 0 and (state ~= "InvestigateNoise" or s.heard >= s.investigating) then
		return go("InvestigateNoise", "heard")
	end
	if state == "InvestigateNoise" then
		if s.stateDone then
			return go("Patrol", "nothing found")
		end
		return go("InvestigateNoise", "searching")
	end
	return go("Patrol", "patrolling")
end

--------------------------------------------------------------------------------
-- Catches
--------------------------------------------------------------------------------

function Brain.catchKind(check: CatchCheck): Enums.JumpscareKind?
	if check.busy or not check.canHunt or check.hidden or check.stunned then
		return nil
	end
	if check.creatureInWater or check.targetSwimming then
		return nil -- in the water the pool's telegraphed grab is the only catch
	end
	if not check.playing or check.hiding or not check.lineClear then
		return nil
	end
	if check.creatureInVent ~= check.targetInVent then
		return nil
	end
	if check.creatureInVent then
		return if check.distance <= SENSES.VentCatchDistance then "Vent" else nil
	end
	if check.horizontal <= SENSES.CatchDistance and check.vertical <= CATCH_VERTICAL then
		return "Hallway"
	end
	return nil
end

-- The speed of a state on a difficulty (Scripted moves at its own pace).
function Brain.speedFor(state: string, difficulty: Enums.Difficulty): number
	local base = CreatureConfig.Speeds[state] or CreatureConfig.Speeds.Patrol
	if state == "Scripted" then
		return base
	end
	local spec = DifficultyConfig[difficulty] or DifficultyConfig.Standard
	return base * spec.creatureSpeedMultiplier
end

--------------------------------------------------------------------------------
-- Level knowledge
--------------------------------------------------------------------------------

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
	local loops = Brain.patrolLoops(layout.anchors, function(anchor: LayoutSchema.Anchor): Vector3
		return worldCFrame(id, anchor).Position
	end)
	local waypoints: { Waypoint } = {}
	for _, loop in loops do
		for _, waypoint in loop.waypoints do
			table.insert(waypoints, waypoint)
		end
	end
	local rooms: { [string]: Room } = {}
	local roomList: { Room } = {}
	local roomRects: { [string]: LayoutSchema.Rect } = {}
	for _, room in layout.rooms do
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
		-- Level 4 fairness: the Creature leaves the pool only through its own vent route, never climbing out at the deck
		made.ventExitOnly = CreatureConfig.Water.VentExitOnly
		table.insert(basins, made)
	end
	local spawn: CFrame? = nil
	for _, anchor in layout.anchors do
		if anchor.kind == "CreatureSpawn" then
			spawn = worldCFrame(id, anchor)
			break
		end
	end
	return {
		levelId = id :: Enums.LevelId,
		origin = origin,
		loops = loops,
		waypoints = waypoints,
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
