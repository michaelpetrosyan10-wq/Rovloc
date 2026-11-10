--!strict
-- Hiding spots beyond the locker (docs/MONSTER.md 8): HideSpotService's rules for lockers, barrels and cabinets alike,
-- on a fake clock with every dependency injected and real built props (HideBuilder). The pure rules (the stay clock,
-- the pull-out, the hurried entry, the seeded fake-outs, the throw's landing), barrels and cabinets tracked by the
-- Hideable tag with their lid and door swinging and torn off (LockerMotion), getting in heard (HideEnter, or
-- HideEnterHurried straight off a sprint), the stay limit (the knock at 35 s, the shove at 45 s, held while a breath
-- check runs), fake-outs (the reveal for the hider alone, one per floor per player, the spot ordinary after), the
-- teammate's pull-out (beside the puller, the brain told, refused from too far or from inside a spot), the inspector
-- serving every sniffing state, and the brain's view of a level's spots.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LockerMotion = require(ReplicatedStorage.Shared.Sequence.LockerMotion)
local Rng = require(ReplicatedStorage.Shared.Util.Rng)
local SynthPresets = require(ReplicatedStorage.Shared.Audio.SynthPresets)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)

local HideBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.HideBuilder)
local PropKit = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Props.PropKit)

local HideSpotService = require(ServerScriptService.Services.Mechanics.HideSpotService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

type Cue = { player: Player, payload: Types.PrivateCuePayload }

type World = {
	now: number,
	teleports: { { player: Player, cframe: CFrame } },
	cues: { Cue },
	notes: { string },
	noises: { { kind: Enums.NoiseKind, source: Player? } },
	reveals: { { player: Player, kind: string } },
	pulled: { Player },
	life: { [Player]: Enums.LifeState },
	move: { [Player]: Enums.MoveState },
	bodies: { [Player]: CFrame },
	clear: boolean,
	state: Enums.MonsterState,
	creature: Vector3?,
	players: { Player },
}

local W = Attributes.World
local H = CreatureConfig.Hiding
local LEAD = GameConfig.OneShotLead
local ROOT_HEIGHT = 3
local LEVEL: Enums.LevelId = "Level0_Basement"
local SEED = 99
local STEP = 0.05

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local nextUserId = 8800

local function newPlayer(): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "HideSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	return player
end

local function build(kind: "Barrel" | "Cabinet", id: string, at: Vector3, exit: ("Left" | "Right")?): Model
	local folder = Instance.new("Folder")
	folder.Name = "SpecHides"
	local spec: HideBuilder.HideSpec = {
		cframe = CFrame.new(at),
		anchorId = id,
		levelId = LEVEL,
		zoneId = "L0_Tunnel_Spec",
		number = 1,
		exit = exit,
	}
	if kind == "Barrel" then
		return HideBuilder.buildBarrel(folder, spec, Rng.new(5))
	end
	return HideBuilder.buildCabinet(folder, spec, Rng.new(5))
end

local function anchor(model: Model, name: string): CFrame
	local found = PropKit.findAttachment(model, name)
	assert(found, model.Name .. " has " .. name)
	return PropKit.attachmentWorld(found)
end

local function scares(world: World, player: Player, kind: Enums.ScareKind): number
	local total = 0
	for _, cue in world.cues do
		if cue.player == player and cue.payload.kind == "Scare" and cue.payload.args.scare == kind then
			total += 1
		end
	end
	return total
end

local function install(world: World)
	HideSpotService.SetDependencies({
		now = function(): number
			return world.now
		end,
		teleport = function(player: Player, cframe: CFrame): boolean
			table.insert(world.teleports, { player = player, cframe = cframe })
			world.bodies[player] = cframe
			return true
		end,
		lock = function(_player: Player) end,
		unlock = function(_player: Player) end,
		pushOverride = function(_player: Player) end,
		popOverride = function(_player: Player) end,
		lifeState = function(player: Player): Enums.LifeState
			return world.life[player] or "Alive"
		end,
		moveState = function(player: Player): Enums.MoveState
			return world.move[player] or "Standing"
		end,
		controlLock = function(_player: Player): Enums.ControlLock
			return "None"
		end,
		body = function(player: Player): (CFrame?, number)
			return world.bodies[player], ROOT_HEIGHT
		end,
		clear = function(_cframe: CFrame, _model: Model): boolean
			return world.clear
		end,
		oneShot = function(_kind, _startAt, _args, _subject) end,
		cue = function(player: Player, payload: Types.PrivateCuePayload)
			table.insert(world.cues, { player = player, payload = payload })
		end,
		notify = function(_player: Player, key: string)
			table.insert(world.notes, key)
		end,
		playAt = function(
			preset: string,
			_position: Vector3,
			_options: AudioService.CueOptions?
		): AudioService.CueHandle?
			local handle: AudioService.CueHandle = {
				id = 1,
				preset = preset,
				looped = SynthPresets.isLooped(preset),
				Stop = function(_self: AudioService.CueHandle, _fade: number?) end,
				IsActive = function(_self: AudioService.CueHandle): boolean
					return false
				end,
			}
			return handle
		end,
		emit = function(_position: Vector3, kind: Enums.NoiseKind, source: Player?, _levelId: string?)
			table.insert(world.noises, { kind = kind, source = source })
		end,
		monsterState = function(): Enums.MonsterState
			return world.state
		end,
		creatureAt = function(): Vector3?
			return world.creature
		end,
		chaser = function(): Player?
			return nil
		end,
		victim = function(): Player?
			return nil
		end,
		stat = function(_player: Player, _key: Enums.StatKey) end,
		refresh = function(_host: Instance) end,
		torchOff = function(_player: Player) end,
		reveal = function(player: Player, kind: string)
			table.insert(world.reveals, { player = player, kind = kind })
		end,
		pulled = function(player: Player)
			table.insert(world.pulled, player)
		end,
	})
end

local function advance(world: World, to: number)
	while world.now < to - 1e-9 do
		world.now = math.min(to, world.now + STEP)
		HideSpotService.Step(world.now)
	end
end

-- Runs `body` in a run (seed SEED) with `count` players on a fake clock; always tears down.
local function inRun(count: number, body: (world: World) -> ())
	local players: { Player } = {}
	for _ = 1, count do
		table.insert(players, newPlayer())
	end
	local world: World = {
		now = 50,
		teleports = {},
		cues = {},
		notes = {},
		noises = {},
		reveals = {},
		pulled = {},
		life = {},
		move = {},
		bodies = {},
		clear = true,
		state = "Patrol",
		creature = nil,
		players = players,
	}
	install(world)
	HideSpotService.BeginRun({
		runId = "hide-spec",
		seed = SEED,
		difficulty = "Standard",
		participants = players,
		startedAt = 0,
	})
	local failure: string? = nil
	xpcall(function()
		body(world)
	end, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end)
	HideSpotService.EndRun()
	HideSpotService.SetDependencies(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

-- Puts `player` in front of `model` (at its EntryAnchor-ish front) and hides them; lets the leaf shut.
local function hideIn(world: World, player: Player, model: Model)
	world.bodies[player] = anchor(model, "ExitAnchor") * CFrame.new(0, ROOT_HEIGHT, 0)
	assert(HideSpotService.Hide(player, model), "hidden in " .. model.Name)
	advance(world, world.now + LockerMotion.OpenSeconds + LockerMotion.StepInSeconds + LockerMotion.CloseSeconds + 0.6)
	assert(HideSpotService.GetState(model) == "Hidden", "settled in " .. model.Name)
end

-- A spot id the run of `seed` arms with a fake-out (and, with `armed` false, one it does not).
local function fakeoutId(seed: number, armed: boolean, skip: string?): string
	for i = 1, 5000 do
		local id = "L0_Hide_" .. i
		if id ~= skip and HideSpotService.isFakeout(seed, id) == armed then
			return id
		end
	end
	error("no such spot id")
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["pure rules: the stay clock, the pull-out, a hurried entry, the seeded fake-outs, the throw's landing"] = function(
		t: Expect
	)
		t.eq(H.KickOutWarning, 35)
		t.eq(H.KickOutSeconds, 45)
		t.eq(HideSpotService.stayVerdict(0, 34.9, false, false, false), nil)
		t.eq(HideSpotService.stayVerdict(0, 35, false, false, false), "Warn")
		t.eq(HideSpotService.stayVerdict(0, 44.9, true, false, false), nil)
		t.eq(HideSpotService.stayVerdict(0, 45, true, false, false), "KickOut")
		t.eq(HideSpotService.stayVerdict(0, 60, true, false, true), nil, "a breath check holds the shove")
		t.eq(HideSpotService.stayVerdict(0, 60, true, true, false), nil, "once out, nothing more")

		local ok = { alive = true, onFoot = true, hiding = false, occupiedByOther = true, distance = H.PullReach }
		t.truthy(HideSpotService.canPull(ok), "a teammate on foot at the exit pulls")
		t.falsy(
			HideSpotService.canPull({
				alive = true,
				onFoot = true,
				hiding = false,
				occupiedByOther = true,
				distance = H.PullReach + 0.1,
			}),
			"too far"
		)
		t.falsy(
			HideSpotService.canPull({ alive = true, onFoot = true, hiding = true, occupiedByOther = true, distance = 1 }),
			"not from inside a spot"
		)
		t.falsy(
			HideSpotService.canPull({
				alive = true,
				onFoot = false,
				hiding = false,
				occupiedByOther = true,
				distance = 1,
			}),
			"not crawling or swimming"
		)
		t.falsy(
			HideSpotService.canPull({
				alive = false,
				onFoot = true,
				hiding = false,
				occupiedByOther = true,
				distance = 1,
			}),
			"not downed"
		)
		t.falsy(
			HideSpotService.canPull({
				alive = true,
				onFoot = true,
				hiding = false,
				occupiedByOther = false,
				distance = 1,
			}),
			"only a teammate's spot"
		)

		t.falsy(HideSpotService.hurried(nil, 10), "never sprinted")
		t.truthy(HideSpotService.hurried(10 - H.HurriedWindow, 10), "sprinting a moment ago")
		t.falsy(HideSpotService.hurried(10 - H.HurriedWindow - 0.01, 10), "a while ago")

		local armed = 0
		local differs = false
		for i = 1, 1200 do
			local id = "Spot_" .. i
			local a = HideSpotService.isFakeout(SEED, id)
			t.eq(HideSpotService.isFakeout(SEED, id), a, "seeded: the same spot rolls the same")
			if a then
				armed += 1
			end
			if HideSpotService.isFakeout(SEED + 1, id) ~= a then
				differs = true
			end
		end
		t.truthy(armed >= 60 and armed <= 145, "about one spot in 12 (" .. armed .. " of 1200)")
		t.truthy(differs, "another run arms other spots")

		local exit = CFrame.lookAt(Vector3.new(0, 0, 0), Vector3.new(0, 0, -1))
		local land = HideSpotService.pullSpot(exit, Vector3.new(4, 3, -2))
		assert(land, "a landing")
		t.near(land.Position.X, 4, 1e-6)
		t.near(land.Position.Y, 0, 1e-6, "at the exit's floor")
		t.near(land.Position.Z, -2, 1e-6)
		t.truthy(land.LookVector:Dot(Vector3.new(4, 0, -2).Unit) > 0.999, "facing away from the spot")
		t.eq(HideSpotService.pullSpot(exit, Vector3.new(0, 3, 0)), nil, "on the exit itself: the spot's own exit")
	end,

	["barrels and cabinets: tracked by Hideable, the lid and the door swing, a rip throws the leaf"] = function(
		t: Expect
	)
		inRun(1, function(world: World)
			local player = world.players[1]
			local barrel = build("Barrel", fakeoutId(SEED, false), Vector3.new(10, 0, 10))
			local cabinet = build(
				"Cabinet",
				fakeoutId(SEED, false, Attributes.getString(barrel, W.AnchorId, "")),
				Vector3.new(30, 0, 10)
			)
			for _, model in { barrel, cabinet } do
				t.truthy(model:HasTag(Tags.Hideable), model.Name .. " is Hideable")
				t.falsy(model:HasTag(Tags.HideableLocker), "not a locker")
				t.truthy(HideSpotService.Track(model), "tracked")
				t.truthy(PropKit.findPrompt(model, "PullOut") ~= nil, "a Pull out prompt beside the Hide prompt")
			end
			t.eq(HideSpotService.GetKind(barrel), "Barrel")
			t.eq(HideSpotService.GetKind(cabinet), "Cabinet")
			local filter = HideSpotService.HideHandler.filter
			assert(filter, "filter")
			t.truthy(filter(barrel, Instance.new("ProximityPrompt")), "the Hide prompt serves a barrel")

			-- the barrel's lid swings open as they climb in, and shut once settled
			world.bodies[player] = anchor(barrel, "ExitAnchor") * CFrame.new(0, ROOT_HEIGHT, 0)
			t.truthy(HideSpotService.Hide(player, barrel))
			local schedule = LockerMotion.enterSchedule(world.now + LEAD)
			advance(world, schedule.moveAt + 0.01)
			local open = PropKit.leafTransform(barrel, "Lid")
			assert(open, "the lid")
			local want = HideBuilder.lidTransform(1)
			t.truthy(
				open.Position:FuzzyEq(want.Position, 1e-3) and open.LookVector:FuzzyEq(want.LookVector, 1e-3),
				"lid open"
			)
			local inside = world.teleports[#world.teleports]
			t.truthy(
				(inside.cframe.Position - (anchor(barrel, "HideAnchor").Position + Vector3.new(0, ROOT_HEIGHT, 0))).Magnitude
					< 1e-3,
				"moved onto the HideAnchor"
			)
			advance(world, schedule.settledAt + 0.1)
			t.eq(HideSpotService.GetState(barrel), "Hidden")
			local shut = PropKit.leafTransform(barrel, "Lid")
			assert(shut, "the lid")
			t.truthy(shut.Position.Magnitude < 1e-3, "lid shut")

			-- a cabinet's door, and a rip throws it to its landing
			t.truthy(LockerMotion.pose(cabinet, "Swing", 1))
			local door = PropKit.leafTransform(cabinet, "Door")
			assert(door, "the door")
			t.truthy(door.LookVector:FuzzyEq(HideBuilder.doorTransform(1).LookVector, 1e-3), "door open")
			t.truthy(LockerMotion.pose(cabinet, "Smash", 1))
			local base = cabinet.PrimaryPart
			assert(base, "base")
			local landing = base:FindFirstChild("DoorLanding") :: Attachment
			local rest = PropKit.leafRest(cabinet, "Door")
			local leaf = cabinet:FindFirstChild("Door") :: Model
			assert(rest and leaf, "the door's rest and leaf")
			t.truthy(
				(leaf.WorldPivot.Position - (base.CFrame * landing.CFrame).Position).Magnitude < 1e-3,
				"the torn door lies at its landing"
			)
		end)
	end,

	["getting in is heard: HideEnter, HideEnterHurried straight off a sprint"] = function(t: Expect)
		inRun(2, function(world: World)
			local quiet, hurried = world.players[1], world.players[2]
			local a = build("Barrel", fakeoutId(SEED, false), Vector3.new(10, 0, 10))
			local b = build(
				"Cabinet",
				fakeoutId(SEED, false, Attributes.getString(a, W.AnchorId, "")),
				Vector3.new(30, 0, 10)
			)
			HideSpotService.Track(a)
			HideSpotService.Track(b)
			world.move[hurried] = "Sprinting"
			advance(world, world.now + 0.3)
			world.move[hurried] = "Standing"
			advance(world, world.now + 0.3)
			hideIn(world, hurried, b)
			hideIn(world, quiet, a)
			t.eq(#world.noises, 2)
			t.eq(world.noises[1].kind, "HideEnterHurried", "sprinting within the last second")
			t.eq(world.noises[1].source, hurried)
			t.eq(world.noises[2].kind, "HideEnter")
			t.eq(world.noises[2].source, quiet)
		end)
	end,

	["the stay limit: the knock at 35 s, the shove out at 45 s, held while a breath check runs"] = function(t: Expect)
		inRun(1, function(world: World)
			local player = world.players[1]
			local barrel = build("Barrel", fakeoutId(SEED, false), Vector3.new(10, 0, 10))
			HideSpotService.Track(barrel)
			local since = world.now
			hideIn(world, player, barrel)
			advance(world, since + H.KickOutWarning - 0.1)
			t.eq(scares(world, player, "HideWarn"), 0, "not yet")
			advance(world, since + H.KickOutWarning + 0.1)
			t.eq(scares(world, player, "HideWarn"), 1, "the warning knock")
			t.truthy(table.find(world.notes, HideSpotService.WarnHint) ~= nil, "and the hint")
			advance(world, since + H.KickOutSeconds - 0.1)
			t.eq(HideSpotService.GetOccupant(barrel), player, "still inside")
			advance(world, since + H.KickOutSeconds + 0.1)
			t.eq(scares(world, player, "HideKick"), 1, "shoved out")
			t.eq(HideSpotService.GetOccupant(barrel), nil, "out")
			local out = world.teleports[#world.teleports]
			t.eq(out.player, player)
			t.truthy(
				(out.cframe.Position - (anchor(barrel, "ExitAnchor").Position + Vector3.new(0, ROOT_HEIGHT, 0))).Magnitude
					< 1e-3,
				"unhurt, at the spot's exit"
			)

			-- a breath check running at 45 s holds the shove until it ends
			advance(world, world.now + 2)
			local cabinet = build(
				"Cabinet",
				fakeoutId(SEED, false, Attributes.getString(barrel, W.AnchorId, "")),
				Vector3.new(30, 0, 10)
			)
			HideSpotService.Track(cabinet)
			local again = world.now
			hideIn(world, player, cabinet)
			advance(world, again + H.KickOutSeconds - 1)
			t.truthy(HideSpotService.StartCheck(player, LockerMotion.PeekMax), "a breath check starts")
			t.truthy(HideSpotService.SetHeld(player, true), "holding")
			advance(world, again + H.KickOutSeconds + 0.5)
			t.eq(HideSpotService.GetOccupant(cabinet), player, "the check holds the shove")
			advance(world, again + H.KickOutSeconds + LockerMotion.WarnSeconds + LockerMotion.PeekMax + 0.5)
			HideSpotService.SetHeld(player, false)
			advance(world, world.now + 0.2)
			t.eq(HideSpotService.GetOccupant(cabinet), nil, "shoved out once it ended")
		end)
	end,

	["fake-outs: the reveal for the hider alone, at most one per floor per player, the spot ordinary after"] = function(
		t: Expect
	)
		inRun(2, function(world: World)
			local first, second = world.players[1], world.players[2]
			local idA = fakeoutId(SEED, true)
			local idB = fakeoutId(SEED, true, idA)
			local a = build("Barrel", idA, Vector3.new(10, 0, 10))
			local b = build("Cabinet", idB, Vector3.new(30, 0, 10))
			HideSpotService.Track(a)
			HideSpotService.Track(b)
			local at = world.now
			world.bodies[first] = anchor(a, "ExitAnchor") * CFrame.new(0, ROOT_HEIGHT, 0)
			t.truthy(HideSpotService.Hide(first, a))
			advance(world, at + LEAD + HideSpotService.FakeoutDelay - 0.02)
			t.eq(#world.reveals, 0, "not before the leaf starts to open")
			advance(world, at + LEAD + HideSpotService.FakeoutDelay + 0.03)
			t.eq(#world.reveals, 1, "the mask leaps out")
			t.eq(world.reveals[1].player, first, "for the one who opened it")
			t.eq(world.reveals[1].kind, "Fakeout")
			advance(world, world.now + 2)
			t.eq(HideSpotService.GetOccupant(a), first, "nothing else: they are hidden")
			t.truthy(HideSpotService.RequestExit(first), "and step out")
			advance(world, world.now + 2)

			-- their floor's fake-out is spent: the second armed spot is ordinary for them
			world.bodies[first] = anchor(b, "ExitAnchor") * CFrame.new(0, ROOT_HEIGHT, 0)
			t.truthy(HideSpotService.Hide(first, b))
			advance(world, world.now + 2)
			t.eq(#world.reveals, 1, "one per floor per player")
			t.truthy(HideSpotService.RequestExit(first))
			advance(world, world.now + 2)

			-- the played spot is ordinary for everyone; the teammate's own budget still gets b
			world.bodies[second] = anchor(a, "ExitAnchor") * CFrame.new(0, ROOT_HEIGHT, 0)
			t.truthy(HideSpotService.Hide(second, a))
			advance(world, world.now + 2)
			t.eq(#world.reveals, 1, "the played spot is safe after")
			t.truthy(HideSpotService.RequestExit(second))
			advance(world, world.now + 2)
			world.bodies[second] = anchor(b, "ExitAnchor") * CFrame.new(0, ROOT_HEIGHT, 0)
			t.truthy(HideSpotService.Hide(second, b))
			advance(world, world.now + 2)
			t.eq(#world.reveals, 2, "b is still armed for a player who has not had one on this floor")
			t.eq(world.reveals[2].player, second)
		end)
	end,

	["the pull-out: a teammate drags the hider out beside them, the brain is told; refused from too far"] = function(
		t: Expect
	)
		inRun(2, function(world: World)
			local hider, puller = world.players[1], world.players[2]
			local cabinet = build("Cabinet", fakeoutId(SEED, false), Vector3.new(30, 0, 10), "Left")
			HideSpotService.Track(cabinet)
			local handler = HideSpotService.PullHandler
			local filter, canUse, audience = handler.filter, handler.canUse, handler.audience
			assert(filter and canUse and audience, "the pull handler")
			t.falsy(filter(cabinet, Instance.new("ProximityPrompt")), "no Pull out on an empty spot")
			hideIn(world, hider, cabinet)
			t.truthy(filter(cabinet, Instance.new("ProximityPrompt")), "shown while a teammate hides inside")
			t.eq(audience(Instance.new("ProximityPrompt"), cabinet), "Others", "never to the hider")
			t.eq(cabinet:GetAttribute(W.OwnerUserId), hider.UserId, "the hider owns it meanwhile")

			local exit = anchor(cabinet, "ExitAnchor")
			world.bodies[puller] = exit * CFrame.new(0, ROOT_HEIGHT, -(H.PullReach + 1))
			local far = canUse(puller, Instance.new("ProximityPrompt"), cabinet)
			t.falsy(far, "too far from the exit")
			t.falsy(HideSpotService.Pull(puller, cabinet))
			world.bodies[puller] = exit * CFrame.new(1.5, ROOT_HEIGHT, -2)
			t.truthy((canUse(puller, Instance.new("ProximityPrompt"), cabinet)), "a teammate at the exit may pull")
			t.eq(H.PullSeconds, 1.2)
			local hold = handler.holdSeconds
			assert(hold, "hold")
			t.eq(hold(puller, Instance.new("ProximityPrompt"), cabinet), H.PullSeconds)

			t.truthy(HideSpotService.Pull(puller, cabinet), "pulled")
			t.eq(world.pulled[1], hider, "the brain is told: no exit catch, a startle")
			t.eq(scares(world, hider, "HideKick"), 1)
			t.eq(HideSpotService.GetOccupant(cabinet), nil)
			t.eq(HideSpotService.GetLockerOf(hider), nil)
			local thrown = world.teleports[#world.teleports]
			t.eq(thrown.player, hider)
			local pullerAt = (exit * CFrame.new(1.5, ROOT_HEIGHT, -2)).Position
			t.near(thrown.cframe.Position.X, pullerAt.X, 1e-3, "beside the puller")
			t.near(thrown.cframe.Position.Z, pullerAt.Z, 1e-3)
			t.near(thrown.cframe.Position.Y, exit.Position.Y + ROOT_HEIGHT, 1e-3, "on the exit's floor")
			local away = Vector3.new(pullerAt.X - exit.Position.X, 0, pullerAt.Z - exit.Position.Z).Unit
			t.truthy(thrown.cframe.LookVector:Dot(away) > 0.99, "facing away from the spot")

			-- nobody pulls a spot they are hiding in themselves, and a blocked landing uses the spot's own exit
			advance(world, world.now + 2)
			hideIn(world, hider, cabinet)
			world.clear = false
			local before = #world.teleports
			world.clear = true
			world.bodies[puller] = exit * CFrame.new(0, ROOT_HEIGHT, 0)
			t.truthy(HideSpotService.Pull(puller, cabinet), "standing on the exit")
			t.eq(#world.teleports, before + 1)
			t.truthy(
				(world.teleports[#world.teleports].cframe.Position - (exit.Position + Vector3.new(0, ROOT_HEIGHT, 0))).Magnitude
					< 1e-3,
				"to the spot's own exit"
			)
		end)
	end,

	["the inspector serves every sniffing state; the brain sees a level's spots by their fronts"] = function(t: Expect)
		inRun(1, function(world: World)
			local player = world.players[1]
			local barrel = build("Barrel", fakeoutId(SEED, false), Vector3.new(10, 0, 10))
			local cabinet = build(
				"Cabinet",
				fakeoutId(SEED, false, Attributes.getString(barrel, W.AnchorId, "")),
				Vector3.new(30, 0, 10)
			)
			HideSpotService.Track(barrel)
			HideSpotService.Track(cabinet)
			local spots = HideSpotService.SpotsOn(LEVEL)
			t.eq(#spots, 2, "both spots of the level")
			for _, spot in spots do
				t.truthy(
					spot.front.Position:FuzzyEq(anchor(spot.id :: Model, "ExitAnchor").Position, 1e-4),
					"the front is the ExitAnchor"
				)
			end
			t.eq(#HideSpotService.SpotsOn("Level4_FloodedPool"), 0, "another level's spots are not")

			for _, sniffing in { "Search", "HidingResponse", "InvestigateNoise" } do
				world.state = "Patrol"
				hideIn(world, player, barrel)
				world.state = sniffing :: Enums.MonsterState
				world.creature = anchor(barrel, "ExitAnchor").Position
				local result: { verdict: Types.LockerVerdict? } = { verdict = nil }
				local thread = coroutine.create(function()
					result.verdict = HideSpotService.Inspect(barrel)
				end)
				assert(coroutine.resume(thread))
				HideSpotService.SetHeld(player, true)
				local _, _, windowEnd = HideSpotService.GetCheck(player)
				assert(windowEnd, sniffing .. ": a check runs")
				advance(world, windowEnd + 0.1)
				HideSpotService.SetHeld(player, false)
				t.eq(result.verdict, "HiddenSafe", sniffing .. ": held through the check")
				world.state = "Patrol"
				t.truthy(HideSpotService.RequestExit(player), "and out again")
				advance(world, world.now + 2)
			end
			hideIn(world, player, barrel)
			world.state = "Search"
			world.creature = Vector3.new(500, 0, 500)
			local walked: { verdict: Types.LockerVerdict? } = { verdict = nil }
			local thread = coroutine.create(function()
				walked.verdict = HideSpotService.Inspect(barrel)
			end)
			assert(coroutine.resume(thread))
			advance(world, world.now + 0.2)
			t.eq(walked.verdict, "HiddenSafe", "away from the front, the check ends safe")
		end)
	end,
}
