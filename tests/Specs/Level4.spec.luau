--!strict
-- Level 4 (Phase 7): the flooded pool's controller. Its rules: when a pool session calls the Creature to the water
-- (waiting while it is asleep or busy, never while it already hunts), what the floodlights blind, the lever's throw,
-- where the water beats can sound on the real layout, never the same beat twice in a row, beats only out of sight in
-- the band, the nearest lamp. The live controller on a fake clock with injected swimmers, Creature, lamps, switch and
-- senders: the emergency switch (On, the prompt closed, the lever thrown over the server's steps, the strike-up
-- timeline naming all nine lamps, the lamps lit for the run when it starts and restored at the run's end, the held
-- swimmer released first, otherwise the Creature blinded with the stun stat, everyone told, one use only), the pool
-- session's single alert and its cooldown, and the ambience director. Registered with the Levels service.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LayoutSchema = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LayoutSchema)
local Scenes = require(ReplicatedStorage.Shared.Sequence.Scenes)
local Types = require(ReplicatedStorage.Shared.Types)
local WorldConfig = require(ReplicatedStorage.Shared.Config.WorldConfig)

local Levels = require(ServerScriptService.Services.Levels)
local Level4 = require(ServerScriptService.Services.Levels.Level4_FloodedPoolController)
local FloodedPoolService = require(ServerScriptService.Services.Mechanics.FloodedPoolService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Floodlight = Level4.Floodlight

type World = {
	now: number,
	players: { Player },
	roots: { [Player]: Vector3 },
	swimmers: { Player },
	creature: Vector3?,
	state: Enums.MonsterState,
	alerts: { { position: Vector3, priority: Enums.NoisePriority, at: number } },
	stuns: { { seconds: number, from: Vector3 } },
	releaseResult: boolean,
	releases: { string },
	lights: { Floodlight },
	poses: { { lever: number, lit: boolean } },
	refreshed: { Instance },
	shots: { { kind: Enums.OneShotKind, startAt: number, args: { [string]: Types.OneShotArg } } },
	sounds: { { preset: string, position: Vector3, volume: number?, at: number } },
	notices: { { player: Player, key: string } },
	stats: { { player: Player, key: Enums.StatKey } },
	clear: boolean,
}

local W = Attributes.World
local L4: Enums.LevelId = "Level4_FloodedPool"
local SEED = 4404
local ORIGIN = WorldConfig.levelOrigin(L4)
local WEST_DECK = ORIGIN + Vector3.new(110, 3, 60)

local nextUserId = 9800

local function newPlayer(name: string): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = name
	local writable = player :: any
	writable.UserId = nextUserId
	return player
end

local function runContext(): Types.RunContext
	return { runId = "level4-spec", seed = SEED, difficulty = "Standard", participants = {}, startedAt = 0 }
end

local function levelContext(): Types.LevelContext
	return { levelId = L4, run = runContext(), root = Instance.new("Model"), runtime = Instance.new("Folder") }
end

-- The nine Floodlight fixtures of the real layout, each with a stand-in part (dark, as built).
local function layoutLights(): { Floodlight }
	local layout = Builder.getLayout(L4)
	assert(layout, "Level 4 layout")
	local out: { Floodlight } = {}
	for _, room in layout.rooms do
		for _, light in (room.lights or {}) :: { LayoutSchema.Light } do
			if light.kind == "Floodlight" then
				local part = Instance.new("Part")
				part.Name = light.id
				part:SetAttribute(W.BaseBrightness, 0)
				local entry: Floodlight = {
					id = light.id,
					part = part :: BasePart,
					position = ORIGIN + light.pos,
					brightness = light.brightness,
				}
				table.insert(out, entry)
			end
		end
	end
	table.sort(out, function(a: Floodlight, b: Floodlight): boolean
		return a.id < b.id
	end)
	return out
end

local function switchModel(): Model
	local model = Instance.new("Model")
	model.Name = "L4_FloodlightSwitch"
	local base = Instance.new("Part")
	base.Name = "Base"
	base.CFrame = CFrame.new(ORIGIN + Vector3.new(91.5, 4, 70))
	base.Parent = model
	model.PrimaryPart = base
	model:SetAttribute(W.On, false)
	model:SetAttribute(W.LevelId, L4)
	return model
end

-- Runs `body` with the controller active on a fake world (see World), and always tears it down.
local function onLevel(body: (world: World) -> ())
	local player = newPlayer("PoolWarden")
	local world: World = {
		now = 1000,
		players = { player },
		roots = { [player] = WEST_DECK },
		swimmers = {},
		creature = ORIGIN + Vector3.new(170, -4, 100),
		state = "Patrol",
		alerts = {},
		stuns = {},
		releaseResult = false,
		releases = {},
		lights = layoutLights(),
		poses = {},
		refreshed = {},
		shots = {},
		sounds = {},
		notices = {},
		stats = {},
		clear = false,
	}
	Level4.SetDependencies({
		now = function(): number
			return world.now
		end,
		players = function(): { Player }
			return world.players
		end,
		rootOf = function(p: Player): Vector3?
			return world.roots[p]
		end,
		eyeOf = function(p: Player): Vector3?
			local root = world.roots[p]
			return if root then root + Vector3.new(0, 1.5, 0) else nil
		end,
		lineClear = function(_a: Vector3, _b: Vector3): boolean
			return world.clear
		end,
		swimmers = function(): { Player }
			return world.swimmers
		end,
		creature = function(): (Vector3?, Enums.MonsterState)
			return world.creature, world.state
		end,
		alert = function(position: Vector3, priority: Enums.NoisePriority)
			table.insert(world.alerts, { position = position, priority = priority, at = world.now })
		end,
		stun = function(seconds: number, from: Vector3)
			table.insert(world.stuns, { seconds = seconds, from = from })
		end,
		releaseGrab = function(outcome: FloodedPoolService.Outcome): boolean
			table.insert(world.releases, outcome)
			return world.releaseResult
		end,
		floodlights = function(): { Floodlight }
			return world.lights
		end,
		setBase = function(part: BasePart, brightness: number)
			part:SetAttribute(W.BaseBrightness, brightness)
		end,
		poseSwitch = function(_model: Model, lever: number, lit: boolean)
			table.insert(world.poses, { lever = lever, lit = lit })
		end,
		refresh = function(host: Instance)
			table.insert(world.refreshed, host)
		end,
		oneShot = function(
			kind: Enums.OneShotKind,
			startAt: number,
			args: { [string]: Types.OneShotArg },
			_subject: Instance?
		)
			table.insert(world.shots, { kind = kind, startAt = startAt, args = args })
		end,
		playAt = function(preset: string, position: Vector3, volume: number?)
			table.insert(world.sounds, { preset = preset, position = position, volume = volume, at = world.now })
		end,
		notify = function(p: Player, key: string)
			table.insert(world.notices, { player = p, key = key })
		end,
		stat = function(p: Player, key: Enums.StatKey)
			table.insert(world.stats, { player = p, key = key })
		end,
	})
	Level4.BeginRun(runContext())
	Level4.Activate(levelContext())
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err) .. "\n" .. debug.traceback()
	end, world)
	Level4.Deactivate()
	Level4.EndRun()
	Level4.SetDependencies(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

local function step(world: World, seconds: number, dt: number?)
	local stepSize = dt or 0.1
	local target = world.now + seconds
	while world.now < target - 1e-9 do
		world.now = math.min(target, world.now + stepSize)
		Level4.Step(world.now)
	end
end

local function soundsOf(world: World, preset: string): number
	local count = 0
	for _, sound in world.sounds do
		if sound.preset == preset then
			count += 1
		end
	end
	return count
end

return {
	["Level4: registered with the Levels service"] = function(t: Expect)
		t.eq(Levels.Level4, Level4)
		t.eq(Level4.Controller.LevelId, L4)
		t.eq(Level4.LevelId, L4)
	end,

	["Level4 rules: the pool session's alert, the blinding and the lever"] = function(t: Expect)
		local base: Level4.AlertInput = {
			swimming = true,
			alerted = false,
			alertAt = 10,
			cooldownUntil = 0,
			now = 12,
			state = "Patrol",
		}
		local function decide(changes: { [string]: any }): string
			local input = table.clone(base) :: any
			for key, value in changes do
				input[key] = value
			end
			return Level4.poolAlert(input)
		end
		t.eq(decide({}), "Alert", "a swimmer and a wandering Creature")
		t.eq(decide({ state = "InvestigateNoise" }), "Alert")
		t.eq(decide({ now = 9 }), "Wait", "not before the session's moment")
		t.eq(decide({ cooldownUntil = 20 }), "Wait", "not inside the cooldown")
		t.eq(decide({ state = "Dormant" }), "Wait", "asleep: wait for it")
		t.eq(decide({ state = "Stunned" }), "Wait")
		t.eq(decide({ state = "Scripted" }), "Wait")
		t.eq(decide({ state = "AquaticStalk" }), "Done", "it already stalks the water")
		t.eq(decide({ state = "WallChase" }), "Done")
		t.eq(decide({ alerted = true }), "Done", "once per session")
		t.eq(decide({ swimming = false }), "Done", "nobody in the water")

		local low, high = Vector3.new(0, -10, 0), Vector3.new(100, 30, 100)
		t.truthy(Level4.blinds(Vector3.new(50, -5, 50), "Patrol", low, high), "in the natatorium")
		t.falsy(Level4.blinds(Vector3.new(150, 0, 50), "Patrol", low, high), "in the changing rooms")
		t.truthy(Level4.blinds(nil, "AquaticStalk", low, high), "stalking the water")
		t.falsy(Level4.blinds(nil, "Patrol", low, high))

		t.eq(Level4.leverAt(0), 0)
		t.near(Level4.leverAt(Level4.LeverSeconds), 1, 1e-6, "home at ON")
		local peak = 0
		local last = -1
		local rising = true
		for i = 1, 40 do
			local value = Level4.leverAt(Level4.LeverSeconds * i / 40)
			if i <= 32 and value < last then
				rising = false
			end
			last = value
			peak = math.max(peak, value)
		end
		t.truthy(rising, "heaved up in one throw")
		t.truthy(peak > 1 and peak < 1.1, "a little overshoot")
		t.near(Level4.leverAt(10), 1, 1e-6)
	end,

	["Level4 rules: beat candidates on the real layout, picks and placement"] = function(t: Expect)
		local layout = Builder.getLayout(L4)
		assert(layout, "Level 4 layout")
		local candidates = Level4.candidates(layout)
		t.truthy(#candidates.water >= 40, "the open water")
		t.truthy(#candidates.ceiling >= 40, "under the roofs")
		local basin = (layout.basins or {})[1]
		assert(basin, "the basin")
		for _, point in candidates.water do
			local localPoint = point - ORIGIN
			t.near(localPoint.Y, basin.waterLevel + 0.1, 1e-4, "just over the surface")
			t.truthy(localPoint.X > basin.rect.x and localPoint.X < basin.rect.x + basin.rect.w, "over the basin (x)")
			t.truthy(localPoint.Z > basin.rect.z and localPoint.Z < basin.rect.z + basin.rect.d, "over the basin (z)")
		end
		local random = Random.new(3)
		local kinds: { Level4.BeatKind } = { "Drip", "Slosh", "TileFall", "Groan" }
		local previous: Level4.BeatKind? = nil
		for _ = 1, 50 do
			local kind: Level4.BeatKind? = Level4.pickBeat(random, previous, kinds)
			local repeated = (kind :: string?) == (previous :: string?)
			t.truthy(kind ~= nil and not repeated, "never the same twice in a row")
			previous = kind
		end
		t.eq(Level4.pickBeat(random, "Drip", { "Drip" }), nil, "nothing else allowed")
		local never = function(_a: Vector3, _b: Vector3): boolean
			return false
		end
		local always = function(_a: Vector3, _b: Vector3): boolean
			return true
		end
		local listener = ORIGIN + Vector3.new(150, 0, 80)
		local eyes = { listener + Vector3.new(0, 1.5, 0) }
		local point = Level4.place("Drip", candidates, listener, eyes, never, random)
		assert(point, "a drip in the band")
		local distance = Vector3.new(point.X - listener.X, 0, point.Z - listener.Z).Magnitude
		t.truthy(distance >= Level4.BandMin and distance <= Level4.BandMax, "in the band")
		local groan = Level4.place("Groan", candidates, listener, eyes, never, random)
		t.truthy(groan ~= nil and (groan :: Vector3).Y - ORIGIN.Y > 10, "a groan under a roof")
		t.eq(Level4.place("Slosh", candidates, listener, eyes, always, random), nil, "never where it can be seen")
		local lights = layoutLights()
		t.eq(#lights, 9, "nine floodlights")
		local nearest = Level4.nearestLight(lights[1].position + Vector3.new(0.5, 0, 0), lights)
		t.eq(nearest, lights[1].position)
		t.eq(Level4.nearestLight(Vector3.zero, {}), nil)
	end,

	["live: the emergency floodlights"] = function(t: Expect)
		onLevel(function(world: World)
			local switch = switchModel()
			local player = world.players[1]
			t.truthy(Level4.Flip(player, switch), "thrown")
			t.truthy(Attributes.getBool(switch, W.On, false), "On")
			t.eq(world.refreshed[1], switch, "the prompt closes")
			t.eq(soundsOf(world, "FloodlightBreaker"), 1, "the clank at the switch")
			t.eq(#world.shots, 1)
			local shot = world.shots[1]
			t.eq(shot.kind, "Timeline")
			t.eq(shot.args.id, Scenes.FloodlightsId)
			for index, arg in Scenes.FloodlightArgs do
				t.eq(shot.args[arg], world.lights[index].id, arg .. " names a lamp")
			end
			t.near(shot.startAt, world.now + GameConfig.OneShotLead + Level4.BreakerDelay, 1e-6)
			t.falsy(Level4.Flip(player, switch), "one use per run")
			t.falsy(Level4.Flip(player, switchModel()), "even from another switch")
			-- The lever, server-stepped.
			step(world, Level4.LeverSeconds + 0.05, 0.05)
			t.truthy(#world.poses >= 5, "posed every step")
			t.truthy(world.poses[1].lever < 1, "thrown over several steps")
			t.near(world.poses[#world.poses].lever, 1, 1e-6, "home at ON")
			t.truthy(world.poses[#world.poses].lit, "the green lamp")
			t.falsy(world.poses[1].lit, "not lit before it is up")
			-- The lamps come up when the strike-up starts.
			for _, light in world.lights do
				t.eq(Attributes.getNumber(light.part :: BasePart, W.BaseBrightness, -1), 0, "still dark")
			end
			step(world, shot.startAt - world.now + 0.01, 0.01)
			for _, light in world.lights do
				t.eq(Attributes.getNumber(light.part :: BasePart, W.BaseBrightness, -1), light.brightness, light.id)
			end
			t.eq(soundsOf(world, "FloodlightStrike"), 1)
			t.eq(world.releases[1], "Floodlight", "a held swimmer would be let go first")
			t.eq(#world.stuns, 1, "nobody held: the Creature in the natatorium is blinded")
			t.eq(world.stuns[1].seconds, GameConfig.StunSeconds)
			t.eq(world.stats[1].player, player)
			t.eq(world.stats[1].key, "Stuns")
			t.eq(world.notices[1].key, Level4.OnKey)
			t.truthy(Level4.IsFlipped())
		end)
		-- The run's end puts the lamps back.
		onLevel(function(world: World)
			Level4.Flip(world.players[1], switchModel())
			step(world, 1)
			t.eq(
				Attributes.getNumber(world.lights[1].part :: BasePart, W.BaseBrightness, -1),
				world.lights[1].brightness
			)
			Level4.EndRun()
			for _, light in world.lights do
				t.eq(
					Attributes.getNumber(light.part :: BasePart, W.BaseBrightness, -1),
					0,
					"dark again for the next run"
				)
			end
		end)
		-- A held swimmer released by the lights: the pool service stuns it, not the controller.
		onLevel(function(world: World)
			world.releaseResult = true
			Level4.Flip(world.players[1], switchModel())
			step(world, 1)
			t.eq(#world.stuns, 0, "the release's own stun")
			t.eq(#world.stats, 0)
		end)
		-- A Creature away from the pool is not blinded.
		onLevel(function(world: World)
			world.creature = ORIGIN + Vector3.new(30, 3, 50)
			Level4.Flip(world.players[1], switchModel())
			step(world, 1)
			t.eq(#world.stuns, 0, "in the changing rooms")
		end)
	end,

	["live: a pool session calls the Creature to the water once"] = function(t: Expect)
		onLevel(function(world: World)
			local swimmer = world.players[1]
			step(world, 20)
			t.eq(#world.alerts, 0, "nobody swims")
			world.state = "Dormant"
			world.swimmers = { swimmer }
			world.roots[swimmer] = ORIGIN + Vector3.new(140, -1, 60)
			local entered = world.now
			step(world, 12)
			t.eq(#world.alerts, 0, "it sleeps: the alert waits")
			world.state = "Patrol"
			step(world, 1.5)
			t.eq(#world.alerts, 1, "called")
			t.eq(world.alerts[1].priority, "Normal")
			t.eq(world.alerts[1].position, world.roots[swimmer], "to the swimmer")
			t.truthy(world.alerts[1].at - entered >= Level4.AlertMin)
			step(world, 5)
			t.eq(#world.alerts, 1, "once per session")
			world.swimmers = {}
			step(world, 2)
			world.swimmers = { swimmer }
			step(world, 10)
			t.eq(#world.alerts, 1, "a new session inside the cooldown")
			world.swimmers = {}
			step(world, 30)
			world.swimmers = { swimmer }
			step(world, Level4.AlertMax + 1.5)
			t.eq(#world.alerts, 2, "after the cooldown a new session calls it again")
			t.eq(Level4.AlertCount(), 2)
			world.swimmers = {}
			step(world, 2)
			world.state = "AquaticStalk"
			world.swimmers = { swimmer }
			step(world, 60)
			t.eq(#world.alerts, 2, "already stalking: no alert")
		end)
		onLevel(function(world: World)
			local swimmer = world.players[1]
			world.swimmers = { swimmer }
			world.roots[swimmer] = ORIGIN + Vector3.new(140, -1, 60)
			local entered = world.now
			step(world, Level4.AlertMax + 1.2)
			t.eq(#world.alerts, 1)
			local delay = world.alerts[1].at - entered
			t.truthy(delay >= Level4.AlertMin and delay <= Level4.AlertMax + 1.1, "4-7 s into the session")
		end)
	end,

	["live: the water beats"] = function(t: Expect)
		onLevel(function(world: World)
			local first = Level4.GetNextBeatAt()
			t.truthy(first >= world.now + Level4.BeatMin and first <= world.now + Level4.BeatMax, "the first beat")
			local presets: { [string]: boolean } = {}
			for _, preset in Level4.BeatPresets do
				presets[preset] = true
			end
			local beats: { { preset: string, position: Vector3, at: number } } = {}
			local disturbed = false
			while #beats < 14 and world.now < 3000 do
				world.now += 0.1
				if not disturbed and #beats == 4 then
					disturbed = true
					local due = Level4.GetNextBeatAt()
					Level4.NoteDisturbance(due - 1)
					local before = #beats
					while world.now < due + Level4.QuietGap - 1.2 do
						world.now += 0.1
						Level4.Step(world.now)
					end
					t.eq(#beats, before, "quiet after a grab")
				end
				local count = #world.sounds
				Level4.Step(world.now)
				for index = count + 1, #world.sounds do
					local sound = world.sounds[index]
					if presets[sound.preset] then
						table.insert(beats, { preset = sound.preset, position = sound.position, at = world.now })
					end
				end
			end
			t.eq(#beats, 14, "beats keep coming")
			for index, beat in beats do
				local distance = Vector3.new(beat.position.X - WEST_DECK.X, 0, beat.position.Z - WEST_DECK.Z).Magnitude
				t.truthy(distance >= Level4.BandMin and distance <= Level4.BandMax, "in the band")
				if index > 1 then
					t.truthy(beat.preset ~= beats[index - 1].preset, "never the same twice in a row")
					local gap = beat.at - beats[index - 1].at
					t.truthy(gap >= Level4.BeatMin - 0.2, "spaced")
				end
			end
			t.eq(Level4.BeatsPlayed(), 14)
			world.clear = true
			local before = #world.sounds
			step(world, 120)
			t.eq(#world.sounds, before, "nowhere out of sight: silence")
		end)
	end,
}
