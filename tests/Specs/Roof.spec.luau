--!strict
-- Level 3: the roof controller. Its rules on the real layout: the housing, the door and the spot behind it, who is
-- still inside, when the squad is out (and clear of the door), when the door goes, when the Creature steps onto the
-- ledge, where it stands there and whom it stares at; the door scene as data. Then the live controller on a fake
-- clock with an injected squad, Creature, door, jumps and senders: the Creature held hidden from the start, the door
-- opening for the first arrival, the door sequence (slam, stage, reveal, smash, the chase, RUN), a straggler inside
-- (no slam, no reveal in sight), the ledge staging for a squad and for a solo jumper (every jumper escaping once, at
-- the landing, their hold ended there), a downed teammate who does not hold it, a straggler on the roof who does, a
-- Creature that is busy (asked for again), the dev staging, and deactivation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local ParachuteMotion = require(ReplicatedStorage.Shared.Sequence.ParachuteMotion)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local Timeline = require(ReplicatedStorage.Shared.Sequence.Timeline)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Levels = require(ServerScriptService.Services.Levels)
local Roof = require(ServerScriptService.Services.Levels.Level3_RoofController)
local MonsterAIService = require(ServerScriptService.Services.Monster.MonsterAIService)
local ParachuteService = require(ServerScriptService.Services.Mechanics.ParachuteService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Handle = MonsterAIService.ScriptedHandle
type Jump = ParachuteService.Jump

type Shot = { kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg } }

type World = {
	now: number,
	players: { Player },
	roots: { [Player]: Vector3 },
	life: { [Player]: Enums.LifeState },
	jumps: { [Player]: Jump },
	clear: boolean,
	calls: { { name: string, at: number, value: any } },
	acquirable: boolean,
	acquires: number,
	stares: { Player | boolean },
	creature: Vector3?,
	door: Model,
	doorState: Enums.DoorState,
	doorCalls: { { state: Enums.DoorState, seconds: number?, at: number } },
	shots: { Shot },
	released: { Player },
	notices: { { player: Player, key: string } },
	escaped: { Player },
	escapedAt: { number },
}

local ROOF: Enums.LevelId = "Level3_Roof"
local DECK = ParachuteMotion.DeckY
local STAND = 3
local GAP = ParachuteMotion.Gap
local GAP_Z = (GAP.minZ + GAP.maxZ) / 2

-- The middle stair housing and its roof door, from the layout and WorldConfig: the doorway on the housing's wall
-- shared with the roof (deck height), `OUT` the way out through it, the tower that comes up into the housing.
local ROOF_LAYOUT = Builder.getLayout(ROOF) :: LayoutSchema.LevelLayout
local ROOF_ROOMS = LayoutSchema.indexRooms(ROOF_LAYOUT)
local HOUSING = ROOF_ROOMS.L3_RoofAccess.rect
local DOORWAY, OUT = (function(): (Vector3, Vector3)
	local edge = LayoutSchema.sharedEdge(HOUSING, ROOF_ROOMS.L3_Roof_East.rect) :: LayoutSchema.SharedEdge
	for _, door in ROOF_LAYOUT.doors do
		if door.scriptedId == "RoofStairDoor" then
			local at = WorldConfig.levelOrigin(ROOF)
				+ (
					if edge.axis == "X"
						then Vector3.new(edge.coord, 0, door.at)
						else Vector3.new(door.at, 0, edge.coord)
				)
			local centre = WorldConfig.levelOrigin(ROOF)
				+ Vector3.new(HOUSING.x + HOUSING.w / 2, 0, HOUSING.z + HOUSING.d / 2)
			local away = at - centre
			local out = if edge.axis == "X"
				then Vector3.new(if away.X < 0 then -1 else 1, 0, 0)
				else Vector3.new(0, 0, if away.Z < 0 then -1 else 1)
			return at, out
		end
	end
	error("the roof has no RoofStairDoor")
end)()
local EAST_TOWER = WorldConfig.Towers.East
local IN_HOUSING = WorldConfig.levelOrigin(ROOF)
	+ Vector3.new(HOUSING.x + HOUSING.w / 2, STAND, DOORWAY.Z - WorldConfig.levelOrigin(ROOF).Z + 6)
local IN_TOWER = WorldConfig.SchoolOrigin
	+ Vector3.new((EAST_TOWER.minX + EAST_TOWER.maxX) / 2, DECK - 12, EAST_TOWER.openingZ)
local OUT_FAR = DOORWAY + OUT * 36 + Vector3.new(0, STAND, 0)
local OUT_NEAR_DOOR = DOORWAY + OUT * 5 + Vector3.new(0, STAND, 0)
local LEFT_FROM = Vector3.new(-3, DECK + 1, GAP_Z)
local LEAD = GameConfig.OneShotLead
local DOOR = Scenes.RoofDoor
local ROOT_HEIGHT = CreatureConfig.Rig.HipHeight + CreatureConfig.Rig.RootSize.Y / 2

local nextUserId = 9500

local function newPlayer(name: string): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = name
	local writable = player :: any
	writable.UserId = nextUserId
	return player
end

local function jump(state: Enums.ParachuteState, at: number, fields: { [string]: any }?): Jump
	local entry: { [string]: any } = {
		state = state,
		since = at,
		leftFrom = LEFT_FROM,
		leftAt = at,
		deployedAt = nil,
		deployFrom = nil,
		velocity = nil,
		auto = false,
		landedAt = nil,
		landedFrom = nil,
		hard = false,
	}
	for key, value in (fields or {}) :: { [string]: any } do
		entry[key] = value
	end
	return (entry :: any) :: Jump
end

local function geometry(): Roof.Geometry
	local layout = Builder.getLayout(ROOF)
	assert(layout, "the roof layout")
	return Roof.geometry(layout)
end

local function fakeHandle(world: World): Handle
	local function record(name: string, value: any)
		table.insert(world.calls, { name = name, at = world.now, value = value })
	end
	local handle: Handle
	handle = {
		MoveTo = function(_self: Handle, position: Vector3, _speed: number?)
			record("MoveTo", position)
		end,
		Teleport = function(_self: Handle, cframe: CFrame)
			world.creature = cframe.Position
			record("Teleport", cframe)
		end,
		SetPose = function(_self: Handle, poseMode: Enums.PoseMode)
			record("SetPose", poseMode)
		end,
		SetHidden = function(_self: Handle, hidden: boolean)
			record("SetHidden", hidden)
		end,
		Face = function(_self: Handle, position: Vector3)
			record("Face", position)
		end,
		Release = function(_self: Handle, nextState: Enums.MonsterState?)
			record("Release", nextState)
		end,
	}
	return handle
end

local function callsNamed(world: World, name: string): { { name: string, at: number, value: any } }
	local out: { { name: string, at: number, value: any } } = {}
	for _, call in world.calls do
		if call.name == name then
			table.insert(out, call)
		end
	end
	return out
end

local function shotsOf(world: World, kind: Enums.OneShotKind, id: string?): { Shot }
	local out: { Shot } = {}
	for _, shot in world.shots do
		if shot.kind == kind and (id == nil or shot.args.id == id) then
			table.insert(out, shot)
		end
	end
	return out
end

-- Runs `body` with the controller active on a fake world (one participant per name, all in the housing), and always
-- tears it down.
local function onRoof(names: { string }, body: (world: World, players: { Player }) -> ())
	local players: { Player } = {}
	local door = Instance.new("Model")
	door.Name = "Door_L3_Door_RoofStair"
	local world: World = {
		now = 2000,
		players = players,
		roots = {},
		life = {},
		jumps = {},
		clear = false,
		calls = {},
		acquirable = true,
		acquires = 0,
		stares = {},
		creature = DOORWAY - OUT * 7 + Vector3.new(0, ROOT_HEIGHT, -10),
		door = door,
		doorState = "Closed",
		doorCalls = {},
		shots = {},
		released = {},
		notices = {},
		escaped = {},
		escapedAt = {},
	}
	for _, name in names do
		local player = newPlayer(name)
		table.insert(players, player)
		world.roots[player] = IN_HOUSING
		world.life[player] = "Alive"
	end
	local handle = fakeHandle(world)
	Roof.SetDependencies({
		now = function(): number
			return world.now
		end,
		players = function(): { Player }
			local out: { Player } = {}
			for _, player in world.players do
				local state = world.life[player]
				if state == "Alive" or state == "Downed" then
					table.insert(out, player)
				end
			end
			return out
		end,
		rootOf = function(player: Player): Vector3?
			return world.roots[player]
		end,
		eyeOf = function(player: Player): Vector3?
			local root = world.roots[player]
			return if root then root + Vector3.new(0, 1.5, 0) else nil
		end,
		lineClear = function(_from: Vector3, _to: Vector3): boolean
			return world.clear
		end,
		lifeState = function(player: Player): Enums.LifeState
			return world.life[player] or "Lobby"
		end,
		acquire = function(_token: string): Handle?
			world.acquires += 1
			return if world.acquirable then handle else nil
		end,
		stare = function(_token: string, player: Player?): boolean
			table.insert(world.stares, if player then player else false)
			return true
		end,
		creatureRoot = function(): Vector3?
			return world.creature
		end,
		door = function(): Model?
			return world.door
		end,
		doorState = function(_door: Model): Enums.DoorState
			return world.doorState
		end,
		setDoor = function(_door: Model, state: Enums.DoorState, seconds: number?): boolean
			table.insert(world.doorCalls, { state = state, seconds = seconds, at = world.now })
			world.doorState = state
			return true
		end,
		oneShot = function(
			kind: Enums.OneShotKind,
			startAt: number,
			args: { [string]: Types.OneShotArg },
			_subject: Instance?
		)
			table.insert(world.shots, { kind = kind, startAt = startAt, args = args })
		end,
		jump = function(player: Player): Jump?
			return world.jumps[player]
		end,
		releaseHold = function(player: Player): boolean
			table.insert(world.released, player)
			return true
		end,
		notify = function(player: Player, key: string)
			table.insert(world.notices, { player = player, key = key })
		end,
	})
	local connection = Roof.Escaped:Connect(function(player: Player)
		table.insert(world.escaped, player)
		table.insert(world.escapedAt, world.now)
	end)
	local run: Types.RunContext =
		{ runId = "roof-spec", seed = 55, difficulty = "Standard", participants = players, startedAt = 0 }
	Roof.BeginRun(run)
	Roof.Activate({ levelId = ROOF, run = run, root = Instance.new("Model"), runtime = Instance.new("Folder") })
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, world, players)
	connection:Disconnect()
	Roof.Deactivate()
	Roof.EndRun()
	Roof.SetDependencies(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function step(world: World, seconds: number, dt: number?)
	local size = dt or 0.1
	local target = world.now + seconds
	while world.now < target - 1e-9 do
		world.now = math.min(target, world.now + size)
		Roof.Step(world.now)
	end
end

-- Walks everyone out onto the roof and runs the door sequence through the release.
local function smashAndRelease(t: Expect, world: World)
	for player in world.roots do
		world.roots[player] = OUT_FAR
	end
	-- it waits behind the door for its grace (ObjectiveConfig.graceFor) once someone is out
	local waited = 0
	while Roof.GetPhase() == "Arrival" and waited < Roof.SmashTimeout + 1 do
		step(world, 0.1)
		waited += 0.1
	end
	t.eq(Roof.GetPhase(), "Smash", "the door sequence starts")
	step(world, DOOR.Release + LEAD + 0.2)
	t.eq(Roof.GetPhase(), "Chase", "the chase is on")
end

-- `player` jumps (at the gap) and opens the canopy now.
local function openCanopy(world: World, player: Player)
	world.roots[player] = Vector3.new(-10, DECK - 30, GAP_Z)
	world.jumps[player] = jump("Canopy", world.now, {
		deployedAt = world.now,
		deployFrom = LEFT_FROM,
		velocity = ParachuteMotion.canopyVelocity(Vector3.new(-1, 0, 0), false),
	})
end

local function land(world: World, player: Player)
	world.roots[player] = Vector3.new(-70, ParachuteMotion.GroundY + STAND, GAP_Z)
	local current = world.jumps[player]
	world.jumps[player] = jump("Landed", world.now, {
		leftAt = if current then current.leftAt else world.now,
		deployedAt = if current then current.deployedAt else world.now,
		landedAt = world.now,
	})
end

return {
	["Roof: the geometry from the layout"] = function(t: Expect)
		local g = geometry()
		t.eq(g.doorway, DOORWAY, "the door in the housing's west wall")
		t.eq(DOORWAY.X, HOUSING.x, "(on the roof side of the housing)")
		t.eq(g.out, Vector3.new(-1, 0, 0), "out onto the roof")
		t.eq(g.behind.Position, DOORWAY - OUT * 3 + Vector3.new(0, ROOT_HEIGHT, 0), "right behind the door")
		t.truthy(g.behind.LookVector:Dot(g.out) > 0.99, "facing it")
		t.truthy(Roof.inside(IN_HOUSING, g), "the housing")
		t.truthy(Roof.inside(IN_TOWER, g), "the stair tower under it")
		t.falsy(Roof.inside(OUT_FAR, g), "out on the roof")
		t.falsy(Roof.inside(OUT_NEAR_DOOR, g), "just through the door")
		t.truthy(g.cue.X < g.doorway.X and g.cue.Y > DECK, "the door's sounds come from the roof side")
	end,

	["Roof: when the squad is out and when the door goes"] = function(t: Expect)
		local g = geometry()
		local allOut, anyOut = Roof.squadOut({ { position = OUT_FAR }, { position = IN_HOUSING } }, g)
		t.falsy(allOut, "someone is still inside")
		t.truthy(anyOut)
		allOut, anyOut = Roof.squadOut({ { position = OUT_FAR }, { position = OUT_NEAR_DOOR } }, g)
		t.falsy(allOut, "someone is in the doorway")
		allOut = Roof.squadOut({ { position = OUT_FAR }, { position = IN_TOWER } }, g)
		t.falsy(allOut, "someone is still climbing the stairs")
		allOut, anyOut = Roof.squadOut({ { position = IN_TOWER } }, g)
		t.falsy(allOut or anyOut, "nobody has come out yet")
		allOut = Roof.squadOut({ { position = OUT_FAR }, { position = OUT_FAR + Vector3.new(0, 0, 9) } }, g)
		t.truthy(allOut, "everyone out and clear")
		t.falsy((Roof.squadOut({}, g)), "nobody at all")
		local grace = Roof.SmashTimeout
		local function due(smashNow: boolean, firstOutAt: number?, now: number, g2: number?): boolean
			return Roof.smashDue({
				smashNow = smashNow,
				firstOutAt = firstOutAt,
				grace = g2 or grace,
				activatedAt = 0,
				now = now,
			})
		end
		t.falsy(due(false, nil, 10), "nobody out yet")
		t.truthy(due(true, nil, 1), "a loud noise brings it forward")
		t.falsy(due(false, 5, 5 + grace - 0.1), "it waits out its grace behind the door")
		t.truthy(due(false, 5, 5 + grace), "the grace is over")
		t.truthy(due(false, 5, 5 + 12, 12), "Nightmare's grace is shorter")
		t.truthy(due(false, nil, Roof.ArrivalTimeout), "the arrival timeout")
	end,

	["Roof: when the Creature steps onto the ledge"] = function(t: Expect)
		local function ready(jumped: number, roofAlive: number, lastLeftAt: number?, now: number): boolean
			return Roof.ledgeReady({ jumped = jumped, roofAlive = roofAlive, lastLeftAt = lastLeftAt, now = now })
		end
		t.falsy(ready(0, 0, nil, 100), "nobody jumped")
		t.falsy(ready(1, 1, 10, 100), "someone Alive is still up there")
		t.falsy(ready(1, 0, 10, 10 + Roof.LedgeDelay - 0.1), "a moment after the last jump")
		t.truthy(ready(1, 0, 10, 10 + Roof.LedgeDelay), "then it steps onto the ledge")
		t.truthy(ready(2, 0, nil, 0), "no jump time known: at once")
	end,

	["Roof: the Creature's place on the ledge and its stare"] = function(t: Expect)
		local pose = Roof.revealPose({ LEFT_FROM, LEFT_FROM + Vector3.new(0, -20, 2) })
		t.near(pose.Position.X, Roof.LedgeInset, 1e-3, "on the edge, just in from it")
		t.near(pose.Position.Y, DECK + ROOT_HEIGHT, 1e-3)
		t.near(pose.Position.Z, GAP_Z + 1, 1e-3, "where they went over")
		t.truthy(pose.LookVector:Dot(Vector3.new(-1, 0, 0)) > 0.99, "facing out over them")
		local default = Roof.revealPose({})
		t.truthy(
			default.Position.X > 0 and default.Position.Z >= GAP.minZ and default.Position.Z <= GAP.maxZ,
			"the gap"
		)
		local who = Roof.stareTarget({
			{ who = "far", position = Vector3.new(-90, 20, GAP_Z) },
			{ who = "near", position = Vector3.new(-20, 60, GAP_Z) },
		}, pose.Position)
		t.eq(who, "near", "the one right under it")
		t.eq(Roof.stareTarget({}, pose.Position), nil)
	end,

	["Roof: the door scene is valid and ordered"] = function(t: Expect)
		local spec = Scenes.timelines()[DOOR.Id]
		t.truthy(spec ~= nil, DOOR.Id .. " is registered")
		if spec then
			local errors = Timeline.validate(spec)
			t.eq(#errors, 0, DOOR.Id .. ": " .. table.concat(errors, "; "))
		end
		t.truthy(DOOR.Slam < DOOR.Stage and DOOR.Stage < DOOR.Pounds[1], "shut, then staged, then the blows")
		t.truthy(DOOR.Pounds[3] < DOOR.Reveal and DOOR.Reveal < DOOR.Smash and DOOR.Smash < DOOR.Release)
	end,

	["Roof: the Creature is held hidden and the door opens for the first arrival"] = function(t: Expect)
		onRoof({ "First" }, function(world: World, _players: { Player })
			t.truthy(Roof.IsHolding(), "taken at activation")
			t.eq(callsNamed(world, "SetHidden")[1].value, true, "hidden in the housing")
			step(world, Roof.OpenDelay - 0.2)
			t.eq(#world.doorCalls, 0, "the wind has not caught it yet")
			step(world, 0.4)
			t.eq(world.doorCalls[1].state, "Open", "the door swings open")
			t.eq(Roof.GetPhase(), "Arrival")
		end)
	end,

	["Roof: the door is smashed behind the squad"] = function(t: Expect)
		onRoof({ "One", "Two" }, function(world: World, players: { Player })
			step(world, Roof.OpenDelay + 0.2)
			world.roots[players[1]] = OUT_FAR
			step(world, 1)
			t.eq(Roof.GetPhase(), "Arrival", "one still inside")
			world.roots[players[2]] = OUT_FAR + Vector3.new(0, 0, 6)
			step(world, 0.1)
			t.eq(Roof.GetPhase(), "Arrival", "it waits behind the door for its grace")
			step(world, Roof.SmashTimeout - 0.5)
			t.eq(Roof.GetPhase(), "Smash", "the grace is over")
			local shot = shotsOf(world, "Timeline", DOOR.Id)[1]
			t.truthy(shot ~= nil, "the door scene plays")
			t.truthy(typeof(shot.args.door) == "Vector3", "from the door")
			local start = shot.startAt
			local slam = world.doorCalls[#world.doorCalls]
			t.eq(slam.state, "Closed", "the wind slams it")
			t.eq(slam.seconds, DOOR.SlamSeconds)
			step(world, start + DOOR.Stage + 0.05 - world.now)
			local teleport = callsNamed(world, "Teleport")[1]
			t.truthy(teleport ~= nil and (teleport.value :: CFrame).Position == geometry().behind.Position, "staged")
			step(world, start + DOOR.Reveal + 0.05 - world.now)
			local hidden = callsNamed(world, "SetHidden")
			t.eq(hidden[#hidden].value, false, "shown behind the closed door")
			step(world, start + DOOR.Smash - LEAD + 0.05 - world.now)
			t.eq(world.doorCalls[#world.doorCalls].state, "Smashed", "torn off on the beat")
			step(world, start + DOOR.Release + 0.05 - world.now)
			-- nobody can be seen from behind the doorway: it is left to its senses (it is never told where they are)
			t.eq(callsNamed(world, "Release")[1].value, "Patrol", "let go to find them")
			t.eq(Roof.GetPhase(), "Chase")
			t.eq(#world.notices, 2, "everyone is told to run")
			t.eq(world.notices[1].key, Roof.RunKey)
			local smash = Roof.GetSmash()
			t.truthy(smash ~= nil and smash.slammed and smash.revealed and smash.released)
			t.falsy(Roof.IsHolding())
		end)
	end,

	["Roof: a straggler inside is never shut in or shown the Creature"] = function(t: Expect)
		onRoof({ "Out", "Lingers" }, function(world: World, players: { Player })
			step(world, Roof.OpenDelay + 0.2)
			world.roots[players[1]] = OUT_FAR
			world.clear = true -- the straggler can see the spot behind the open door
			step(world, Roof.SmashTimeout - 0.3)
			t.eq(Roof.GetPhase(), "Arrival")
			step(world, 0.5)
			t.eq(Roof.GetPhase(), "Smash", "the timer runs out")
			for _, call in world.doorCalls do
				t.truthy(call.state ~= "Closed", "never slammed on someone inside")
			end
			step(world, DOOR.Release + LEAD + 0.2)
			for _, call in callsNamed(world, "SetHidden") do
				t.eq(call.value, true, "never shown in sight")
			end
			t.eq(callsNamed(world, "Release")[1].value, "WallChase", "it comes up the stairs after them")
			local smash = Roof.GetSmash()
			t.truthy(smash ~= nil and not smash.slammed and not smash.revealed)
		end)
	end,

	["Roof: the squad jumps, each escapes at the landing, then the Creature takes the ledge"] = function(t: Expect)
		onRoof({ "Ana", "Ben" }, function(world: World, players: { Player })
			local ana, ben = players[1], players[2]
			smashAndRelease(t, world)
			openCanopy(world, ana)
			step(world, Roof.LedgeDelay + 1)
			t.eq(Roof.GetPhase(), "Chase", "Ben is still on the roof")
			land(world, ana)
			local touchdown = world.now
			step(world, 0.1)
			t.eq(world.escaped[1], ana, "Ana escapes at her landing")
			t.truthy(world.escapedAt[1] - touchdown <= 0.11, "timed at the touchdown (her escape time)")
			t.eq(world.released[1], ana, "and her hold ends there")
			openCanopy(world, ben)
			step(world, Roof.LedgeDelay - 0.3)
			t.eq(Roof.GetPhase(), "Chase", "a moment after the last jump")
			step(world, 0.5)
			t.eq(Roof.GetPhase(), "Ledge", "then it takes the ledge")
			t.truthy(Roof.GetLedgeAt() ~= nil)
			t.truthy(Roof.IsHolding(), "held there")
			local teleports = callsNamed(world, "Teleport")
			local ledge = (teleports[#teleports].value :: CFrame).Position
			t.near(ledge.X, Roof.LedgeInset, 1e-3, "on the ledge they jumped from")
			local hidden = callsNamed(world, "SetHidden")
			t.eq(hidden[#hidden].value, false, "shown up there")
			t.eq(world.stares[#world.stares], ben, "staring at the one right under it")
			land(world, ben)
			step(world, 0.2)
			t.eq(world.escaped[2], ben)
			t.eq(world.released[2], ben)
			t.truthy(Roof.HasEscaped(ana) and Roof.HasEscaped(ben))
			step(world, 5)
			t.eq(#world.escaped, 2, "once each")
			t.eq(#world.released, 2)
		end)
	end,

	["Roof: a solo jumper"] = function(t: Expect)
		onRoof({ "Solo" }, function(world: World, players: { Player })
			local solo = players[1]
			smashAndRelease(t, world)
			world.jumps[solo] = jump("Freefall", world.now)
			world.roots[solo] = Vector3.new(-6, DECK - 10, GAP_Z)
			step(world, Roof.LedgeDelay + 0.2)
			t.eq(Roof.GetPhase(), "Ledge", "a falling jumper is off the roof")
			openCanopy(world, solo)
			step(world, 2)
			land(world, solo)
			step(world, 0.2)
			t.eq(#world.escaped, 1)
			t.eq(world.escaped[1], solo)
		end)
	end,

	["Roof: a downed teammate does not hold the ledge; an Alive one on the roof does"] = function(t: Expect)
		onRoof({ "Gone", "Down" }, function(world: World, players: { Player })
			local gone, down = players[1], players[2]
			smashAndRelease(t, world)
			world.life[down] = "Downed"
			world.roots[down] = OUT_FAR
			openCanopy(world, gone)
			step(world, Roof.LedgeDelay + 0.2)
			t.eq(Roof.GetPhase(), "Ledge", "the downed player does not hold it")
		end)
		onRoof({ "Early", "Late" }, function(world: World, players: { Player })
			local early, late = players[1], players[2]
			smashAndRelease(t, world)
			openCanopy(world, early)
			step(world, 1)
			land(world, early)
			world.roots[late] = OUT_FAR
			step(world, 60)
			t.eq(Roof.GetPhase(), "Chase", "the Creature keeps hunting whoever is still up there")
			t.eq(#world.escaped, 1, "the one who jumped got away")
		end)
	end,

	["Roof: a busy Creature is asked for again"] = function(t: Expect)
		onRoof({ "Lone" }, function(world: World, players: { Player })
			local lone = players[1]
			smashAndRelease(t, world)
			world.acquirable = false
			openCanopy(world, lone)
			local asked = world.acquires
			step(world, Roof.LedgeDelay + 1)
			t.eq(Roof.GetPhase(), "Chase", "not on the ledge while it is busy")
			t.truthy(world.acquires > asked + 1, "asked for at the tick rate")
			world.acquirable = true
			step(world, 0.2)
			t.eq(Roof.GetPhase(), "Ledge", "taken once it is free")
		end)
	end,

	["Roof: the dev staging needs a jumper"] = function(t: Expect)
		onRoof({ "Dev" }, function(world: World, players: { Player })
			t.falsy(Roof.StageLedge(), "nobody off the roof yet")
			smashAndRelease(t, world)
			openCanopy(world, players[1])
			t.truthy(Roof.StageLedge(), "staged at once")
			t.eq(Roof.GetPhase(), "Ledge")
			t.falsy(Roof.StageLedge(), "once")
		end)
	end,

	["Roof: leaving the roof lets the Creature go"] = function(t: Expect)
		onRoof({ "Dev" }, function(world: World, players: { Player })
			smashAndRelease(t, world)
			openCanopy(world, players[1])
			step(world, Roof.LedgeDelay + 0.2)
			t.truthy(Roof.IsHolding())
			Roof.Deactivate()
			local releases = callsNamed(world, "Release")
			t.eq(releases[#releases].value, "Dormant", "parked")
			t.eq(Roof.GetPhase(), "Idle")
			t.eq(#Roof.Pending(), 0, "nothing left scheduled")
		end)
	end,

	["Roof: registered with the Levels service"] = function(t: Expect)
		t.eq(Levels.Level3, Roof)
		t.eq(Roof.Controller.LevelId, ROOF)
		t.truthy(Roof.Escaped ~= nil and type(Roof.Escaped.Connect) == "function", "Escaped is a signal")
	end,
}
