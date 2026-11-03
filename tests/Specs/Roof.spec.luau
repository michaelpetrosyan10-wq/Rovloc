--!strict
-- Level 5 (Phase 8): the roof controller. Its rules on the real layout: the housing, the door and the spot behind it,
-- who is still inside, when the squad is out (and clear of the door), when the door goes, the chasing Creature's pace,
-- when the finale starts, where the Creature stands on the ledge and whom it stares at; the roof scenes as data. Then
-- the live controller on a fake clock with an injected squad, Creature, door, jumps and senders: the Creature held
-- hidden from the start, the door opening for the first arrival, the door sequence (slam, stage, reveal, smash, the
-- chase, RUN), a straggler inside (no slam, no reveal in sight), the final sprint (pace and adrenaline), the finale for
-- a squad and for a solo player (the ledge, the stare, two flashes, the reveal and the vanish, the scripted landing,
-- every jumper escaping once), a downed teammate who does not hold it and is hunted after, a straggler who holds it
-- until FinaleWait, a Creature that cannot be taken (the storm alone), a late lander's own fade, and deactivation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ParachuteMotion = require(ReplicatedStorage.Shared.Sequence.ParachuteMotion)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local Timeline = require(ReplicatedStorage.Shared.Sequence.Timeline)
local Types = require(ReplicatedStorage.Shared.Types)

local Levels = require(ServerScriptService.Services.Levels)
local Level5 = require(ServerScriptService.Services.Levels.Level5_RoofController)
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
	alerts: { { position: Vector3, priority: Enums.NoisePriority } },
	creature: Vector3?,
	target: Player?,
	scales: { number },
	door: Model,
	doorState: Enums.DoorState,
	doorCalls: { { state: Enums.DoorState, seconds: number?, at: number } },
	shots: { Shot },
	forced: { Player },
	released: { Player },
	stamina: { [Player]: number },
	refills: { Player },
	notices: { { player: Player, key: string } },
	escaped: { Player },
	escapedAt: { number },
}

local L5: Enums.LevelId = "Level5_Roof"
local DECK = ParachuteMotion.DeckY
local STAND = 3
local GAP = ParachuteMotion.Gap
local GAP_Z = (GAP.minZ + GAP.maxZ) / 2
local IN_HOUSING = Vector3.new(233, DECK + STAND, 86)
local IN_TOWER = Vector3.new(252, DECK - 12, 80)
local OUT_FAR = Vector3.new(190, DECK + STAND, 80)
local OUT_NEAR_DOOR = Vector3.new(221, DECK + STAND, 80)
local LEFT_FROM = Vector3.new(-3, DECK + 1, GAP_Z)
local LEAD = GameConfig.OneShotLead
local DOOR = Scenes.RoofDoor
local FINALE = Scenes.Finale
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

local function geometry(): Level5.Geometry
	local layout = Builder.getLayout(L5)
	assert(layout, "Level 5 layout")
	return Level5.geometry(layout)
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
	door.Name = "Door_L5_Door_RoofStair"
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
		alerts = {},
		creature = Vector3.new(233, DECK + ROOT_HEIGHT, 70),
		target = nil,
		scales = {},
		door = door,
		doorState = "Closed",
		doorCalls = {},
		shots = {},
		forced = {},
		released = {},
		stamina = {},
		refills = {},
		notices = {},
		escaped = {},
		escapedAt = {},
	}
	for _, name in names do
		local player = newPlayer(name)
		table.insert(players, player)
		world.roots[player] = IN_HOUSING
		world.life[player] = "Alive"
		world.stamina[player] = 100
	end
	local handle = fakeHandle(world)
	Level5.SetDependencies({
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
		alert = function(position: Vector3, priority: Enums.NoisePriority)
			table.insert(world.alerts, { position = position, priority = priority })
		end,
		creatureRoot = function(): Vector3?
			return world.creature
		end,
		creatureTarget = function(): Player?
			return world.target
		end,
		setSpeedScale = function(scale: number)
			table.insert(world.scales, scale)
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
		forceLand = function(player: Player): boolean
			table.insert(world.forced, player)
			local current = world.jumps[player]
			world.jumps[player] = jump("Landed", world.now, {
				deployedAt = if current then current.deployedAt else nil,
				landedAt = world.now,
			})
			return true
		end,
		releaseHold = function(player: Player): boolean
			table.insert(world.released, player)
			return true
		end,
		stamina = function(player: Player): number
			return world.stamina[player] or 100
		end,
		refillStamina = function(player: Player)
			table.insert(world.refills, player)
			world.stamina[player] = 100
		end,
		notify = function(player: Player, key: string)
			table.insert(world.notices, { player = player, key = key })
		end,
	})
	local connection = Level5.Escaped:Connect(function(player: Player)
		table.insert(world.escaped, player)
		table.insert(world.escapedAt, world.now)
	end)
	local run: Types.RunContext =
		{ runId = "roof-spec", seed = 55, difficulty = "Standard", participants = players, startedAt = 0 }
	Level5.BeginRun(run)
	Level5.Activate({ levelId = L5, run = run, root = Instance.new("Model"), runtime = Instance.new("Folder") })
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, world, players)
	connection:Disconnect()
	Level5.Deactivate()
	Level5.EndRun()
	Level5.SetDependencies(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function step(world: World, seconds: number, dt: number?)
	local size = dt or 0.1
	local target = world.now + seconds
	while world.now < target - 1e-9 do
		world.now = math.min(target, world.now + size)
		Level5.Step(world.now)
	end
end

-- Walks everyone out onto the roof and runs the door sequence through the release.
local function smashAndRelease(t: Expect, world: World)
	for player in world.roots do
		world.roots[player] = OUT_FAR
	end
	-- it waits behind the door for its grace (ObjectiveConfig.graceFor) once someone is out
	local waited = 0
	while Level5.GetPhase() == "Arrival" and waited < Level5.SmashTimeout + 1 do
		step(world, 0.1)
		waited += 0.1
	end
	t.eq(Level5.GetPhase(), "Smash", "the door sequence starts")
	step(world, DOOR.Release + LEAD + 0.2)
	t.eq(Level5.GetPhase(), "Chase", "the chase is on")
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
		deployedAt = if current then current.deployedAt else world.now,
		landedAt = world.now,
	})
end

return {
	["Level5: the roof's geometry from the layout"] = function(t: Expect)
		local g = geometry()
		t.eq(g.doorway, Vector3.new(226, DECK, 80), "the door in the housing's west wall")
		t.eq(g.out, Vector3.new(-1, 0, 0), "out onto the roof")
		t.eq(g.behind.Position, Vector3.new(229, DECK + ROOT_HEIGHT, 80), "right behind the door")
		t.truthy(g.behind.LookVector:Dot(g.out) > 0.99, "facing it")
		t.truthy(Level5.inside(IN_HOUSING, g), "the housing")
		t.truthy(Level5.inside(IN_TOWER, g), "the stair tower under it")
		t.falsy(Level5.inside(OUT_FAR, g), "out on the roof")
		t.falsy(Level5.inside(OUT_NEAR_DOOR, g), "just through the door")
		t.truthy(g.cue.X < g.doorway.X and g.cue.Y > DECK, "the door's sounds come from the roof side")
	end,

	["Level5: when the squad is out and when the door goes"] = function(t: Expect)
		local g = geometry()
		local allOut, anyOut = Level5.squadOut({ { position = OUT_FAR }, { position = IN_HOUSING } }, g)
		t.falsy(allOut, "someone is still inside")
		t.truthy(anyOut)
		allOut, anyOut = Level5.squadOut({ { position = OUT_FAR }, { position = OUT_NEAR_DOOR } }, g)
		t.falsy(allOut, "someone is in the doorway")
		allOut = Level5.squadOut({ { position = OUT_FAR }, { position = IN_TOWER } }, g)
		t.falsy(allOut, "someone is still climbing the stairs")
		allOut, anyOut = Level5.squadOut({ { position = IN_TOWER } }, g)
		t.falsy(allOut or anyOut, "nobody has come out yet")
		allOut = Level5.squadOut({ { position = OUT_FAR }, { position = OUT_FAR + Vector3.new(0, 0, 9) } }, g)
		t.truthy(allOut, "everyone out and clear")
		t.falsy((Level5.squadOut({}, g)), "nobody at all")
		local grace = Level5.SmashTimeout
		local function due(smashNow: boolean, firstOutAt: number?, now: number, g2: number?): boolean
			return Level5.smashDue({
				smashNow = smashNow,
				firstOutAt = firstOutAt,
				grace = g2 or grace,
				activatedAt = 0,
				now = now,
			})
		end
		t.falsy(due(false, nil, 10), "nobody out yet")
		t.truthy(due(true, nil, 1), "the chain cut (or a loud noise) brings it forward")
		t.falsy(due(false, 5, 5 + grace - 0.1), "it waits out its grace behind the door")
		t.truthy(due(false, 5, 5 + grace), "the grace is over")
		t.truthy(due(false, 5, 5 + 12, 12), "Nightmare's grace is shorter")
		t.truthy(due(false, nil, Level5.ArrivalTimeout), "the arrival timeout")
	end,

	["Level5: the chase's pace"] = function(t: Expect)
		t.eq(Level5.chaseScale(nil, "Standard"), 1, "no target: as configured")
		local near = Level5.chaseScale(4, "Standard")
		local far = Level5.chaseScale(80, "Standard")
		t.truthy(near * CreatureConfig.Speeds.WallChase < GameConfig.SprintSpeed, "never outruns a sprinter")
		t.truthy(near * CreatureConfig.Speeds.WallChase > GameConfig.WalkSpeed, "runs down anyone who stops")
		t.truthy(far * CreatureConfig.Speeds.WallChase > GameConfig.SprintSpeed, "closes a big gap")
		local mid = Level5.chaseScale(27, "Standard")
		t.truthy(mid > near and mid < far, "in between")
		local nightmare = Level5.chaseScale(4, "Nightmare") * CreatureConfig.Speeds.WallChase * 1.2
		t.truthy(nightmare > GameConfig.SprintSpeed - 0.5, "Nightmare keeps pace with a sprinter")
	end,

	["Level5: when the finale starts"] = function(t: Expect)
		local base: Level5.FinaleInput =
			{ jumpers = 1, falling = 0, roofAlive = 0, lastDeployAt = 10, firstLandedAt = nil, now = 10 }
		local function ready(fields: { [string]: any }): boolean
			local input = table.clone(base) :: any
			for key, value in fields do
				input[key] = value
			end
			return Level5.finaleReady(input :: Level5.FinaleInput)
		end
		t.falsy(ready({ jumpers = 0 }), "nobody jumped")
		t.falsy(ready({}), "the canopy just opened")
		t.truthy(ready({ now = 10 + FINALE.Settle }), "settled under the canopy")
		t.falsy(ready({ now = 30, roofAlive = 1 }), "someone is still up there")
		t.falsy(ready({ now = 30, falling = 1 }), "someone is still falling")
		t.truthy(ready({ now = 30, lastDeployAt = nil }), "everyone is down")
		t.truthy(ready({ now = 50, roofAlive = 1, firstLandedAt = 50 - Level5.FinaleWait }), "they waited long enough")
		t.falsy(ready({ jumpers = 0, falling = 0, firstLandedAt = 0, now = 100 }), "nothing to show")
	end,

	["Level5: the Creature's place on the ledge and its stare"] = function(t: Expect)
		local pose = Level5.revealPose({ LEFT_FROM, LEFT_FROM + Vector3.new(0, -20, 2) })
		t.near(pose.Position.X, Level5.LedgeInset, 1e-3, "on the edge, just in from it")
		t.near(pose.Position.Y, DECK + ROOT_HEIGHT, 1e-3)
		t.near(pose.Position.Z, GAP_Z + 1, 1e-3, "where they went over")
		t.truthy(pose.LookVector:Dot(Vector3.new(-1, 0, 0)) > 0.99, "facing out over them")
		local default = Level5.revealPose({})
		t.truthy(
			default.Position.X > 0 and default.Position.Z >= GAP.minZ and default.Position.Z <= GAP.maxZ,
			"the gap"
		)
		local who = Level5.stareTarget({
			{ who = "far", position = Vector3.new(-90, 20, GAP_Z) },
			{ who = "near", position = Vector3.new(-20, 60, GAP_Z) },
		}, pose.Position)
		t.eq(who, "near", "the one right under it")
		t.eq(Level5.stareTarget({}, pose.Position), nil)
	end,

	["Level5: the roof scenes are valid and ordered"] = function(t: Expect)
		local specs = Scenes.timelines()
		for _, id in { DOOR.Id, FINALE.Id, FINALE.SkyId, FINALE.TouchdownId } do
			local spec = specs[id]
			t.truthy(spec ~= nil, id .. " is registered")
			if spec then
				local errors = Timeline.validate(spec)
				t.eq(#errors, 0, id .. ": " .. table.concat(errors, "; "))
			end
		end
		t.truthy(DOOR.Slam < DOOR.Stage and DOOR.Stage < DOOR.Pounds[1], "shut, then staged, then the blows")
		t.truthy(DOOR.Pounds[3] < DOOR.Reveal and DOOR.Reveal < DOOR.Smash and DOOR.Smash < DOOR.Release)
		t.truthy(FINALE.Flash1 < FINALE.Reveal and FINALE.Reveal < FINALE.Flash2, "revealed by the first flash")
		t.truthy(FINALE.Vanish < FINALE.Hide and FINALE.Hide < FINALE.Flash2 + 0.42, "gone before the second strike")
		t.truthy(FINALE.FadeEnd < FINALE.Land and FINALE.Land <= FINALE.Duration, "landed in the dark")
		t.truthy(FINALE.TouchdownFadeEnd < FINALE.TouchdownRelease, "a late lander is let go after their fade")
		t.truthy(FINALE.TouchdownRelease <= FINALE.TouchdownDuration)
	end,

	["Level5: the Creature is held hidden and the door opens for the first arrival"] = function(t: Expect)
		onRoof({ "First" }, function(world: World, _players: { Player })
			t.truthy(Level5.IsHolding(), "taken at activation")
			t.eq(callsNamed(world, "SetHidden")[1].value, true, "hidden in the housing")
			step(world, Level5.OpenDelay - 0.2)
			t.eq(#world.doorCalls, 0, "the wind has not caught it yet")
			step(world, 0.4)
			t.eq(world.doorCalls[1].state, "Open", "the door swings open")
			t.eq(Level5.GetPhase(), "Arrival")
		end)
	end,

	["Level5: the door is smashed behind the squad"] = function(t: Expect)
		onRoof({ "One", "Two" }, function(world: World, players: { Player })
			step(world, Level5.OpenDelay + 0.2)
			world.roots[players[1]] = OUT_FAR
			step(world, 1)
			t.eq(Level5.GetPhase(), "Arrival", "one still inside")
			world.roots[players[2]] = OUT_FAR + Vector3.new(0, 0, 6)
			step(world, 0.1)
			t.eq(Level5.GetPhase(), "Arrival", "it waits behind the door for its grace")
			step(world, Level5.SmashTimeout - 0.5)
			t.eq(Level5.GetPhase(), "Smash", "the grace is over")
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
			t.eq(Level5.GetPhase(), "Chase")
			t.eq(#world.notices, 2, "everyone is told to run")
			t.eq(world.notices[1].key, Level5.RunKey)
			local smash = Level5.GetSmash()
			t.truthy(smash ~= nil and smash.slammed and smash.revealed and smash.released)
			t.falsy(Level5.IsHolding())
		end)
	end,

	["Level5: a straggler inside is never shut in or shown the Creature"] = function(t: Expect)
		onRoof({ "Out", "Lingers" }, function(world: World, players: { Player })
			step(world, Level5.OpenDelay + 0.2)
			world.roots[players[1]] = OUT_FAR
			world.clear = true -- the straggler can see the spot behind the open door
			step(world, Level5.SmashTimeout - 0.3)
			t.eq(Level5.GetPhase(), "Arrival")
			step(world, 0.5)
			t.eq(Level5.GetPhase(), "Smash", "the timer runs out")
			for _, call in world.doorCalls do
				t.truthy(call.state ~= "Closed", "never slammed on someone inside")
			end
			step(world, DOOR.Release + LEAD + 0.2)
			for _, call in callsNamed(world, "SetHidden") do
				t.eq(call.value, true, "never shown in sight")
			end
			t.eq(callsNamed(world, "Release")[1].value, "WallChase", "it comes up the stairs after them")
			local smash = Level5.GetSmash()
			t.truthy(smash ~= nil and not smash.slammed and not smash.revealed)
		end)
	end,

	["Level5: the final sprint"] = function(t: Expect)
		onRoof({ "Runner", "Jumped" }, function(world: World, players: { Player })
			local runner, jumped = players[1], players[2]
			smashAndRelease(t, world)
			world.target = runner
			world.creature = OUT_FAR + Vector3.new(60, 0, 0)
			world.stamina[runner] = 40
			openCanopy(world, jumped)
			world.stamina[jumped] = 10
			step(world, 0.2)
			t.eq(world.scales[#world.scales], Level5.chaseScale(60, "Standard"), "closing a big gap")
			t.eq(world.refills[1], runner, "adrenaline")
			t.eq(#world.refills, 1, "not for someone already in the air")
			world.creature = OUT_FAR + Vector3.new(5, 0, 0)
			step(world, 0.2)
			t.eq(world.scales[#world.scales], Level5.chaseScale(5, "Standard"), "right behind: just under a sprint")
			world.stamina[runner] = 80
			local before = #world.refills
			step(world, 0.2)
			t.eq(#world.refills, before, "no top-up while they have wind")
		end)
	end,

	["Level5: the finale for the squad"] = function(t: Expect)
		onRoof({ "Ana", "Ben" }, function(world: World, players: { Player })
			local ana, ben = players[1], players[2]
			smashAndRelease(t, world)
			world.target = ben
			world.creature = OUT_FAR + Vector3.new(45, 0, 0)
			openCanopy(world, ana)
			step(world, 2)
			t.truthy(world.scales[#world.scales] ~= 1, "the chase pace is in force")
			t.eq(Level5.GetPhase(), "Chase", "Ben is still on the roof")
			land(world, ana)
			local touchdown = world.now
			openCanopy(world, ben)
			step(world, 0.1)
			t.eq(world.escaped[1], ana, "Ana escapes at her landing")
			t.truthy(world.escapedAt[1] - touchdown <= 0.11, "timed at the touchdown (her escape time)")
			t.eq(#world.released, 0, "but she is held for the finale")
			step(world, FINALE.Settle - 0.4)
			t.eq(Level5.GetPhase(), "Chase", "Ben's canopy just opened")
			step(world, 0.5)
			t.eq(Level5.GetPhase(), "Finale")
			t.eq(world.scales[#world.scales], 1, "the pace is restored")
			local shot = shotsOf(world, "Timeline", FINALE.Id)[1]
			t.truthy(shot ~= nil, "the finale plays with the Creature")
			local start = shot.startAt
			t.truthy(typeof(shot.args.head) == "Vector3" and typeof(shot.args.ledge) == "Vector3")
			local flashes = shotsOf(world, "Lightning")
			t.eq(#flashes, 2, "two flashes")
			t.near(flashes[1].startAt, start + FINALE.Flash1, 1e-6)
			t.near(flashes[2].startAt, start + FINALE.Flash2, 1e-6)
			local teleports = callsNamed(world, "Teleport")
			local ledge = (teleports[#teleports].value :: CFrame).Position
			t.near(ledge.X, Level5.LedgeInset, 1e-3, "on the ledge they jumped from")
			t.eq(world.stares[#world.stares], ben, "staring at the one right under it")
			local hiddenBefore = #callsNamed(world, "SetHidden")
			step(world, start + FINALE.Reveal - FINALE.RevealLead + 0.05 - world.now)
			local hidden = callsNamed(world, "SetHidden")
			t.eq(hidden[#hidden].value, false, "revealed by the first flash")
			t.truthy(#hidden > hiddenBefore)
			step(world, start + FINALE.Hide - FINALE.HideLead + 0.05 - world.now)
			hidden = callsNamed(world, "SetHidden")
			t.eq(hidden[#hidden].value, true, "gone at the second")
			t.eq(world.stares[#world.stares], false, "the stare is released")
			t.eq(#world.escaped, 1, "Ben is still in the air")
			t.eq(#world.released, 0, "nobody is let go before the fade")
			step(world, start + FINALE.Land + 0.05 - world.now)
			t.eq(world.forced[1], ben, "Ben is landed in the dark")
			t.eq(#world.escaped, 2, "and escapes there")
			t.truthy(Level5.HasEscaped(ana) and Level5.HasEscaped(ben))
			t.eq(#world.released, 2, "both holds end with the fade: the summary may show")
			t.eq(Level5.GetPhase(), "Done")
			t.truthy(Level5.IsHolding(), "nobody left up there: it stays held")
			step(world, 5)
			t.eq(#world.escaped, 2, "once each")
		end)
	end,

	["Level5: a solo player"] = function(t: Expect)
		onRoof({ "Solo" }, function(world: World, players: { Player })
			local solo = players[1]
			smashAndRelease(t, world)
			world.jumps[solo] = jump("Freefall", world.now)
			step(world, 2)
			t.eq(Level5.GetPhase(), "Chase", "still falling")
			openCanopy(world, solo)
			step(world, FINALE.Settle + 0.2)
			t.eq(Level5.GetPhase(), "Finale")
			step(world, FINALE.Land + LEAD + Level5.FinalePre + 0.2)
			t.eq(#world.escaped, 1)
			t.eq(world.escaped[1], solo)
		end)
	end,

	["Level5: a downed teammate does not hold the finale, and is hunted after it"] = function(t: Expect)
		onRoof({ "Gone", "Down" }, function(world: World, players: { Player })
			local gone, down = players[1], players[2]
			smashAndRelease(t, world)
			world.life[down] = "Downed"
			world.roots[down] = OUT_FAR
			openCanopy(world, gone)
			step(world, FINALE.Settle + 0.2)
			t.eq(Level5.GetPhase(), "Finale", "the downed player does not hold it")
			step(world, FINALE.Land + LEAD + Level5.FinalePre + 0.2)
			t.eq(world.escaped[1], gone)
			t.eq(#world.escaped, 1)
			local releases = callsNamed(world, "Release")
			t.eq(releases[#releases].value, "Patrol", "let go again")
			t.eq(world.alerts[1].position, OUT_FAR, "drawn to whoever is left")
			t.eq(world.alerts[1].priority, "High")
		end)
	end,

	["Level5: a straggler holds the finale until the wait runs out"] = function(t: Expect)
		onRoof({ "Early", "Late" }, function(world: World, players: { Player })
			local early, late = players[1], players[2]
			smashAndRelease(t, world)
			openCanopy(world, early)
			step(world, 1)
			land(world, early)
			world.roots[late] = OUT_FAR
			step(world, Level5.FinaleWait - 0.5)
			t.eq(Level5.GetPhase(), "Chase", "waiting for the straggler")
			step(world, 0.7)
			t.eq(Level5.GetPhase(), "Finale", "not forever")
		end)
	end,

	["Level5: a Creature that cannot be taken leaves the storm alone"] = function(t: Expect)
		onRoof({ "Lone" }, function(world: World, players: { Player })
			local lone = players[1]
			smashAndRelease(t, world)
			world.acquirable = false
			openCanopy(world, lone)
			step(world, FINALE.Settle + 0.2)
			t.eq(Level5.GetPhase(), "FinaleWait", "waiting for it")
			step(world, Level5.AcquireWait + 0.2)
			t.eq(Level5.GetPhase(), "Finale")
			t.eq(#shotsOf(world, "Timeline", FINALE.Id), 0)
			t.eq(#shotsOf(world, "Timeline", FINALE.SkyId), 1, "the storm alone")
			t.eq(#shotsOf(world, "Lightning"), 2)
			step(world, FINALE.Land + LEAD + Level5.FinalePre + 0.2)
			t.eq(world.escaped[1], lone, "they still get away")
		end)
	end,

	["Level5: a late lander gets their own fade"] = function(t: Expect)
		onRoof({ "Quick", "Slow" }, function(world: World, players: { Player })
			local quick, slow = players[1], players[2]
			smashAndRelease(t, world)
			openCanopy(world, quick)
			world.roots[slow] = OUT_FAR
			step(world, 1)
			land(world, quick)
			step(world, Level5.FinaleWait + 0.2)
			t.eq(Level5.GetPhase(), "Finale")
			step(world, FINALE.Land + LEAD + Level5.FinalePre + 0.2)
			t.eq(#world.escaped, 1, "the first one is out")
			openCanopy(world, slow)
			step(world, 4)
			t.eq(#world.escaped, 1, "still in the air")
			land(world, slow)
			step(world, 0.2)
			t.eq(world.escaped[2], slow, "they get away at the landing")
			local touchdown = shotsOf(world, "Timeline", FINALE.TouchdownId)[1]
			t.truthy(touchdown ~= nil and touchdown.args.subject == slow.UserId, "their own fade")
			t.eq(world.released[#world.released], quick, "only Quick has been let go so far")
			step(world, FINALE.TouchdownRelease + LEAD)
			t.eq(world.released[#world.released], slow, "let go after their fade")
			t.eq(#shotsOf(world, "Timeline", FINALE.TouchdownId), 1, "one fade each")
		end)
	end,

	["Level5: leaving the roof lets the Creature go and restores its pace"] = function(t: Expect)
		onRoof({ "Dev" }, function(world: World, players: { Player })
			smashAndRelease(t, world)
			world.target = players[1]
			world.creature = OUT_FAR + Vector3.new(50, 0, 0)
			step(world, 0.2)
			t.truthy(world.scales[#world.scales] ~= 1, "the chase pace is in force")
			Level5.Deactivate()
			t.eq(world.scales[#world.scales], 1, "the pace is restored")
			t.eq(Level5.GetPhase(), "Idle")
			t.eq(#Level5.Pending(), 0, "nothing left scheduled")
		end)
	end,

	["Level5: registered with the Levels service"] = function(t: Expect)
		t.eq(Levels.Level5, Level5)
		t.eq(Level5.Controller.LevelId, L5)
		t.truthy(Level5.Escaped ~= nil and type(Level5.Escaped.Connect) == "function", "Escaped is a signal")
	end,
}
