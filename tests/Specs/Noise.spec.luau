--!strict
-- Noise bus + locomotion sampler. Emit fills every pulse from NoiseConfig (radius, priority, medium per kind) and
-- honours overrides; the ring buffer keeps the newest pulses in order; one player's continuous noise is paced by
-- its interval.
-- The sampler's tier logic is fed fake samples: the louder of the MoveState tier and the observed-speed tier wins,
-- standing still is silent, only server-announced teleports are not footsteps (any other long step is heard at the
-- speed it implies, stall-aware, and reported as suspicious), and pulses respect each kind's interval. Floor debris
-- crunches once per player per volume per cooldown, only during a run.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DebrisNoise = require(ServerScriptService.Services.Core.NoiseAndDirectorService.DebrisNoise)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local NoiseConfig = require(ReplicatedStorage.Shared.Config.NoiseConfig)
local NoiseAndDirectorService = require(ServerScriptService.Services.Core.NoiseAndDirectorService)
local Sampler = require(ServerScriptService.Services.Core.NoiseAndDirectorService.LocomotionNoiseSampler)
local SpecRunner = require(script.Parent.Parent.SpecRunner)
local Tags = require(ReplicatedStorage.Shared.Tags)

type Expect = SpecRunner.Expect

local TICK = 1 / GameConfig.ServerTickHz

local function radiusOf(kind: Enums.NoiseKind?): number
	if kind == nil then
		return 0
	end
	return NoiseConfig.Kinds[kind].radius
end

-- A stand-in for a Player (specs cannot create real ones): Emit only reads UserId, Name and Parent.
local function fakePlayer(userId: number): Player
	return ({ UserId = userId, Name = "NoiseSpec" .. userId, Parent = Players } :: any) :: Player
end

-- Feeds `track` a straight walk along +X at `speed` studs/s, one sample per tick from `startTime` for `seconds`,
-- starting at `startX`. Returns the pulses (kind and time) the sampler asked for, and where the walk ended.
type Pulse = { kind: Enums.NoiseKind, time: number }

local function walk(
	track: Sampler.Track,
	moveState: Enums.MoveState,
	speed: number,
	startTime: number,
	seconds: number,
	startX: number
): ({ Pulse }, number, number)
	local pulses: { Pulse } = {}
	local steps = math.floor(seconds / TICK + 0.5)
	local x = startX
	local time = startTime
	for _ = 1, steps do
		local kind: Enums.NoiseKind? = Sampler.sample(track, Vector3.new(x, 3, 0), moveState, time)
		if kind then
			table.insert(pulses, { kind = kind, time = time })
		end
		x += speed * TICK
		time += TICK
	end
	return pulses, time, x
end

local function assertSpacing(t: Expect, pulses: { Pulse }, what: string)
	for i = 2, #pulses do
		local gap = pulses[i].time - pulses[i - 1].time
		local interval = NoiseConfig.Kinds[pulses[i].kind].interval
		t.truthy(
			gap >= interval - 1e-6,
			string.format("%s: %s pulse %.3fs after the previous one", what, pulses[i].kind, gap)
		)
	end
end

return {
	--------------------------------------------------------------------------------
	-- Emit
	--------------------------------------------------------------------------------

	["Emit takes radius, priority and medium from NoiseConfig for every kind"] = function(t: Expect)
		local position = Vector3.new(12, 3, -40)
		for _, kind: Enums.NoiseKind in Enums.NoiseKind do
			local spec = NoiseConfig.Kinds[kind]
			t.truthy(spec ~= nil, "NoiseConfig has " .. kind)
			local event, emitted = NoiseAndDirectorService.TryEmit(position, kind, { levelId = "Level2_Auditorium" })
			t.truthy(emitted, kind .. " was broadcast")
			t.eq(event.kind, kind)
			t.eq(event.radius, spec.radius, kind .. " radius")
			t.eq(event.priority, spec.priority, kind .. " priority")
			t.eq(event.medium, spec.medium, kind .. " medium")
			t.eq(event.levelId, "Level2_Auditorium", kind .. " level")
			t.eq(event.position, position, kind .. " position")
			t.eq(event.sourceUserId, nil, kind .. " has no source")
			t.truthy(type(event.serverTime) == "number" and event.serverTime == event.serverTime, "server time")
			t.truthy(table.isfrozen(event), "pulses are frozen")
		end
	end,

	["landings: a jump or a fall of 0.32 s or more lands a JumpLand, on foot only"] = function(t: Expect)
		local airborne = 0.32
		t.eq(NoiseConfig.JumpLandAirborne, airborne)
		local track = Sampler.newTrack()
		t.falsy(Sampler.landing(track, false, 10, "Standing"), "on the floor: nothing")
		t.falsy(Sampler.landing(track, true, 10, "Standing"), "taking off")
		t.falsy(Sampler.landing(track, true, 10.2, "Standing"), "in the air")
		t.truthy(Sampler.landing(track, false, 10 + airborne, "Standing"), "a full jump lands loud")
		t.falsy(Sampler.landing(track, false, 10.5, "Standing"), "once")
		local hop = Sampler.newTrack()
		Sampler.landing(hop, true, 20, "Sprinting")
		t.falsy(Sampler.landing(hop, false, 20.2, "Sprinting"), "a short hop (a step down) is quiet")
		local duct = Sampler.newTrack()
		Sampler.landing(duct, true, 30, "VentCrawling")
		t.falsy(Sampler.landing(duct, false, 31, "VentCrawling"), "not in a duct")
		local crouch = Sampler.newTrack()
		Sampler.landing(crouch, true, 40, "Crouching")
		t.truthy(Sampler.landing(crouch, false, 40.5, "Crouching"), "a crouched drop still lands")
	end,

	["Emit uses the spec's noise radii (docs/MONSTER.md 3.1)"] = function(t: Expect)
		local expected: { [string]: number } = {
			CrouchWalk = 5,
			HideEnter = 8,
			SlowVentCrawl = 8,
			GrateUnscrew = 10,
			HideEnterHurried = 14,
			Walk = 22,
			FallingObject = 24,
			ChatMessage = 25,
			JumpLand = 26,
			ObjectiveWork = 34,
			Gasp = 40,
			FlaskShatter = 50,
			Sprint = 60,
			DoorSlam = 90,
			VentScurry = 90,
			ObjectiveClunk = 110,
			GrateKick = 130,
			FloorDebris = 130,
			TrapSnap = 130,
		}
		for kind, radius in expected do
			local event = NoiseAndDirectorService.Emit(Vector3.zero, (kind :: any) :: Enums.NoiseKind)
			t.eq(event.radius, radius, kind)
		end
		t.eq(
			NoiseAndDirectorService.Emit(Vector3.zero, "GrateKick").priority,
			"Critical",
			"kick is instant high priority"
		)
	end,

	["Emit honours medium, vent node, level and radius overrides"] = function(t: Expect)
		local event = NoiseAndDirectorService.Emit(Vector3.new(1, 2, 3), "Walk", {
			levelId = "Level1_Hallways",
			medium = "Vent",
			ventNodeId = "SpecNode",
			radiusMultiplier = 0.5,
		})
		t.eq(event.radius, NoiseConfig.Kinds.Walk.radius * 0.5)
		t.eq(event.medium, "Vent")
		t.eq(event.ventNodeId, "SpecNode")
		t.eq(event.levelId, "Level1_Hallways")
		t.eq(event.priority, NoiseConfig.Kinds.Walk.priority)

		for _, bad in { -1, 0 / 0, math.huge } do
			local scaled = NoiseAndDirectorService.Emit(Vector3.zero, "GrateKick", { radiusMultiplier = bad })
			t.eq(
				scaled.radius,
				NoiseConfig.Kinds.GrateKick.radius,
				"invalid multiplier " .. tostring(bad) .. " ignored"
			)
		end
		t.eq(
			NoiseAndDirectorService.Emit(Vector3.zero, "Sprint", { radiusMultiplier = 0 }).radius,
			0,
			"zero multiplier"
		)
	end,

	["Emit defaults the level to LevelDirector's current level"] = function(t: Expect)
		local current = ReplicatedStorage:GetAttribute(Attributes.Match.CurrentLevel)
		local expected = if type(current) == "string" and Enums.has(Enums.LevelId, current) then current else nil
		local event = NoiseAndDirectorService.Emit(Vector3.zero, "Walk")
		t.eq(event.levelId, expected)
	end,

	["Emit drops pulses at non-finite positions"] = function(t: Expect)
		local before = #NoiseAndDirectorService.RecentNoises(-math.huge)
		local _, emitted = NoiseAndDirectorService.TryEmit(Vector3.new(0 / 0, 0, 0), "Walk")
		t.falsy(emitted, "not broadcast")
		local after = NoiseAndDirectorService.RecentNoises(-math.huge)
		t.truthy(#after == before or #after == NoiseAndDirectorService.RingCapacity, "not buffered")
		for _, event in after do
			t.truthy(event.position == event.position, "no NaN pulse in the buffer")
		end
	end,

	["RecentNoises keeps the newest RingCapacity pulses, oldest first"] = function(t: Expect)
		local capacity = NoiseAndDirectorService.RingCapacity
		t.truthy(capacity >= 64, "ring holds at least 64 pulses")
		local extra = 37
		for i = 1, capacity + extra do
			NoiseAndDirectorService.Emit(Vector3.new(i, 0, 0), "Scripted")
		end
		local all = NoiseAndDirectorService.RecentNoises(-math.huge)
		t.eq(#all, capacity, "bounded by capacity")
		for k, event in all do
			t.eq(event.position.X, extra + k, "slot " .. k)
		end
		t.eq(#NoiseAndDirectorService.RecentNoises(math.huge), 0, "nothing from the future")
		local newest = all[#all]
		local since = NoiseAndDirectorService.RecentNoises(newest.serverTime)
		t.truthy(#since >= 1 and since[#since] == newest, "the newest pulse is included at its own server time")
		for i = 2, #all do
			t.truthy(all[i].serverTime >= all[i - 1].serverTime, "oldest first")
		end
	end,

	["one player's continuous noise is paced per kind"] = function(t: Expect)
		local player = fakePlayer(424201)
		local first, firstEmitted =
			NoiseAndDirectorService.TryEmit(Vector3.new(0, 0, 0), "Walk", { sourcePlayer = player })
		t.truthy(firstEmitted, "first walk pulse")
		t.eq(first.sourceUserId, 424201)
		local second, secondEmitted =
			NoiseAndDirectorService.TryEmit(Vector3.new(1, 0, 0), "Walk", { sourcePlayer = player })
		t.falsy(secondEmitted, "a second walk pulse inside the interval is merged")
		t.eq(second, first, "the standing pulse is returned")
		t.eq(NoiseAndDirectorService.Emit(Vector3.new(2, 0, 0), "Walk", { sourcePlayer = player }), first, "Emit too")
		local _, sprintEmitted =
			NoiseAndDirectorService.TryEmit(Vector3.new(2, 0, 0), "Sprint", { sourcePlayer = player })
		t.truthy(sprintEmitted, "a different kind has its own interval")
		local _, snapA = NoiseAndDirectorService.TryEmit(Vector3.zero, "TrapSnap", { sourcePlayer = player })
		local _, snapB = NoiseAndDirectorService.TryEmit(Vector3.zero, "TrapSnap", { sourcePlayer = player })
		t.truthy(snapA and snapB, "one-shot kinds are never paced")
		local other = fakePlayer(424202)
		local _, otherEmitted = NoiseAndDirectorService.TryEmit(Vector3.zero, "Walk", { sourcePlayer = other })
		t.truthy(otherEmitted, "pacing is per player")
		NoiseAndDirectorService.OnPlayerRemoving(player)
		NoiseAndDirectorService.OnPlayerRemoving(other)
		local _, afterLeave = NoiseAndDirectorService.TryEmit(Vector3.zero, "Walk", { sourcePlayer = player })
		t.truthy(afterLeave, "pacing state is dropped when the player leaves")
		NoiseAndDirectorService.OnPlayerRemoving(player)
	end,

	--------------------------------------------------------------------------------
	-- Sampler tiers (pure)
	--------------------------------------------------------------------------------

	["move states map to their medium and tier"] = function(t: Expect)
		t.eq(Sampler.mediumFor("Standing"), "Air")
		t.eq(Sampler.mediumFor("Crouching"), "Air")
		t.eq(Sampler.mediumFor("VentCrawling"), "Vent")
		t.eq(Sampler.mediumFor("VentScurrying"), "Vent")
		t.eq(Sampler.moveStateTier("Standing"), "Walk")
		t.eq(Sampler.moveStateTier("Sprinting"), "Sprint")
		t.eq(Sampler.moveStateTier("Crouching"), "CrouchWalk")
		t.eq(Sampler.moveStateTier("VentCrawling"), "SlowVentCrawl")
		t.eq(Sampler.moveStateTier("VentScurrying"), "VentScurry")
		for _, silent: Enums.MoveState in { "Hiding", "Trapped", "Parachuting", "Scripted" } :: { Enums.MoveState } do
			t.eq(Sampler.mediumFor(silent), nil, silent .. " has no medium")
			t.eq(Sampler.moveStateTier(silent), nil, silent .. " has no tier")
		end
	end,

	["observed speed picks the medium's tier"] = function(t: Expect)
		t.eq(Sampler.speedTier("Air", 0.5), nil)
		t.eq(Sampler.speedTier("Air", GameConfig.CrouchSpeed), "CrouchWalk")
		t.eq(Sampler.speedTier("Air", GameConfig.WalkSpeed), "Walk")
		t.eq(Sampler.speedTier("Air", GameConfig.SprintSpeed), "Sprint")
		t.eq(Sampler.speedTier("Vent", 0.5), nil)
		t.eq(Sampler.speedTier("Vent", GameConfig.VentCrawlSpeed), "SlowVentCrawl")
		t.eq(Sampler.speedTier("Vent", GameConfig.VentScurrySpeed), "VentScurry")
		t.eq(Sampler.speedTier("Air", 0 / 0), nil, "NaN speed")
	end,

	["the louder of the claimed and the observed tier wins"] = function(t: Expect)
		t.eq(Sampler.classify("Crouching", 14), "Walk", "a crouch that moves at walking speed is a walk")
		t.eq(Sampler.classify("Crouching", 18), "Sprint", "and at sprint speed a sprint")
		t.eq(Sampler.classify("Standing", GameConfig.SprintSpeed), "Sprint", "claiming Standing does not hide a sprint")
		t.eq(Sampler.classify("Sprinting", 3), "Sprint", "a claimed sprint is never quieter than claimed")
		t.eq(Sampler.classify("Crouching", GameConfig.CrouchSpeed), "CrouchWalk")
		t.eq(Sampler.classify("VentCrawling", GameConfig.VentScurrySpeed), "VentScurry")
		t.eq(Sampler.classify("VentCrawling", GameConfig.VentCrawlSpeed), "SlowVentCrawl")
		t.eq(Sampler.louder("Walk", "Sprint"), "Sprint")
		t.eq(Sampler.louder("Sprint", "Walk"), "Sprint")
		t.eq(Sampler.louder("FloorDebris", "GrateKick"), "FloorDebris", "a tie keeps the first")
		t.eq(Sampler.louder(nil, "Walk"), "Walk")
		t.eq(Sampler.louder("Walk", nil), "Walk")

		for _, state: Enums.MoveState in Enums.MoveState do
			local medium: Enums.NoiseMedium? = Sampler.mediumFor(state)
			if medium == nil then
				continue
			end
			for tenth = 0, 300, 5 do
				local speed = tenth / 10
				local kind: Enums.NoiseKind? = Sampler.classify(state, speed)
				local observed: Enums.NoiseKind? = Sampler.speedTier(medium, speed)
				if observed == nil then
					t.eq(kind, nil, string.format("%s standing still at %.1f", state, speed))
				else
					t.truthy(radiusOf(kind) >= radiusOf(observed), state .. " quieter than observed")
					t.truthy(radiusOf(kind) >= radiusOf(Sampler.moveStateTier(state)), state .. " quieter than claimed")
				end
			end
		end
	end,

	["standing still and silent states make no noise"] = function(t: Expect)
		t.eq(Sampler.classify("Sprinting", 0), nil, "a sprint claim without motion is silent")
		t.eq(Sampler.classify("VentScurrying", 0.2), nil)
		t.eq(Sampler.classify("Hiding", 30), nil)
		t.eq(Sampler.classify("Trapped", 30), nil)
		t.eq(Sampler.classify("Parachuting", 30), nil)
	end,

	--------------------------------------------------------------------------------
	-- Sampler motion + pacing (fake samples)
	--------------------------------------------------------------------------------

	["observe measures horizontal speed from root positions"] = function(t: Expect)
		local track = Sampler.newTrack()
		t.eq(Sampler.observe(track, Vector3.new(0, 3, 0), 10), 0, "first sample has no speed")
		t.near(Sampler.observe(track, Vector3.new(1.1, 3, 0), 10.1), 11, 1e-6, "one step")
		t.near(Sampler.observe(track, Vector3.new(2.2, 3, 0), 10.2), 11, 1e-6, "steady")
		t.near(Sampler.observe(track, Vector3.new(2.2, 3, 0), 10.2), 11, 1e-6, "same instant keeps the last speed")

		local falling = Sampler.newTrack()
		for i = 0, 5 do
			Sampler.observe(falling, Vector3.new(0, 100 - i * 8, 0), i * 0.1)
		end
		t.eq(falling.speed, 0, "falling straight down is not movement")

		local teleported = Sampler.newTrack()
		Sampler.observe(teleported, Vector3.new(0, 3, 0), 0)
		Sampler.observe(teleported, Vector3.new(1, 3, 0), 0.1)
		Sampler.armTeleport(teleported, 0.15)
		local jumpSpeed, jumpReport = Sampler.observe(teleported, Vector3.new(400, 3, 0), 0.2)
		t.eq(jumpSpeed, 0, "an announced teleport is not a sprint")
		t.eq(jumpReport, nil, "and is not suspicious")
		t.near(Sampler.observe(teleported, Vector3.new(401.1, 3, 0), 0.3), 11, 1e-3, "walking after the teleport")

		local stale = Sampler.newTrack()
		Sampler.observe(stale, Vector3.new(0, 3, 0), 0)
		t.eq(Sampler.observe(stale, Vector3.new(5, 3, 0), 5), 0, "a long gap restarts the window")

		local speeder = Sampler.newTrack()
		Sampler.observe(speeder, Vector3.new(0, 3, 0), 0)
		local first, report = Sampler.observe(speeder, Vector3.new(20, 3, 0), 0.1)
		t.near(first, 200, 1e-6, "an unannounced 20-stud step in one tick reads as 200 studs/s")
		t.truthy(report ~= nil and math.abs((report :: Sampler.SuspiciousStep).distance - 20) < 1e-6, "and is reported")
		t.truthy(Sampler.observe(speeder, Vector3.new(40, 3, 0), 0.2) >= 150, "sustained impossible speed is heard")
		t.eq(Sampler.classify("Crouching", speeder.speed), "Sprint", "and is as loud as a sprint")
	end,

	["teleports: only a server-announced move is silent"] = function(t: Expect)
		-- Hop 13 studs, hold one tick, repeat: 65 studs/s average that used to read as a string of teleports.
		local hopper = Sampler.newTrack()
		local x, pulses, reports = 0, 0, 0
		for tick = 0, 60 do
			if tick % 2 == 1 then
				x += 13
			end
			local kind, suspicious = Sampler.sample(hopper, Vector3.new(x, 3, 0), "Standing", tick * TICK)
			if kind then
				pulses += 1
				t.eq(kind, "Sprint", "every hop is as loud as a sprint")
			end
			if suspicious then
				reports += 1
				t.truthy(suspicious.speed >= 13 / (2 * TICK) - 1e-6, "hop speed spans the pause before it")
			end
		end
		t.truthy(pulses >= 10, string.format("hop-and-pause is heard (%d pulses)", pulses))
		t.eq(reports, 30, "every unannounced hop is reported")

		-- A token forgives long steps only inside its grace window.
		local late = Sampler.newTrack()
		Sampler.observe(late, Vector3.new(0, 3, 0), 0)
		Sampler.armTeleport(late, 0)
		Sampler.observe(late, Vector3.new(0, 3, 0), 0.5)
		Sampler.observe(late, Vector3.new(0, 3, 0), 1)
		local lateSpeed, lateReport = Sampler.observe(late, Vector3.new(50, 3, 0), Sampler.TeleportGraceSeconds + 0.1)
		t.truthy(lateSpeed > 0 and lateReport ~= nil, "an expired token forgives nothing")

		-- A replication stall followed by a burst reads as the true average speed, not a sprint.
		local stalled = Sampler.newTrack()
		local time = 0
		local position = 0
		for _ = 1, 10 do
			Sampler.observe(stalled, Vector3.new(position, 3, 0), time)
			position += GameConfig.WalkSpeed * TICK
			time += TICK
		end
		local held = position - GameConfig.WalkSpeed * TICK
		for _ = 1, 12 do
			Sampler.observe(stalled, Vector3.new(held, 3, 0), time)
			time += TICK
		end
		local burst = held + GameConfig.WalkSpeed * 1.3
		local burstSpeed = Sampler.observe(stalled, Vector3.new(burst, 3, 0), time)
		t.truthy(burst - held > Sampler.TeleportStep, "the burst is a long step")
		t.eq(Sampler.classify("Standing", burstSpeed), "Walk", "a stalled walk is still a walk")

		-- Server-held states (Hiding, Scripted, ...) are carried by the server: never suspicious, never heard.
		local carried = Sampler.newTrack()
		Sampler.sample(carried, Vector3.new(0, 3, 0), "Scripted", 0)
		local carriedKind, carriedReport = Sampler.sample(carried, Vector3.new(30, 3, 0), "Scripted", TICK)
		t.eq(carriedKind, nil)
		t.eq(carriedReport, nil)
	end,

	["sampled pulses respect each kind's interval"] = function(t: Expect)
		local track = Sampler.newTrack()
		local walking, afterWalk, x = walk(track, "Standing", GameConfig.WalkSpeed, 100, 3, 0)
		t.truthy(#walking >= 5, "a 3 s walk pulses several times")
		for _, pulse in walking do
			t.eq(pulse.kind, "Walk")
		end
		assertSpacing(t, walking, "walk")

		local sprinting = walk(track, "Sprinting", GameConfig.SprintSpeed, afterWalk, 3, x)
		t.truthy(#sprinting >= 7, "a 3 s sprint pulses more often")
		for _, pulse in sprinting do
			t.eq(pulse.kind, "Sprint")
		end
		t.truthy(sprinting[1].time - walking[#walking].time >= NoiseConfig.Kinds.Sprint.interval - 1e-6, "escalation")
		assertSpacing(t, sprinting, "sprint")

		local crouchTrack = Sampler.newTrack()
		local crouching = walk(crouchTrack, "Crouching", GameConfig.CrouchSpeed, 0, 3, 0)
		for _, pulse in crouching do
			t.eq(pulse.kind, "CrouchWalk")
		end
		assertSpacing(t, crouching, "crouch")

		local idleTrack = Sampler.newTrack()
		local idle = walk(idleTrack, "Sprinting", 0, 0, 2, 0)
		t.eq(#idle, 0, "standing still never pulses")
	end,

	["entering a vent restarts the speed window"] = function(t: Expect)
		local track = Sampler.newTrack()
		local _, time, x = walk(track, "Standing", GameConfig.WalkSpeed, 0, 1, 0)
		-- The vent entry moves the root 5 studs in one tick; that jump must not read as a scurry.
		local kind: Enums.NoiseKind? = Sampler.sample(track, Vector3.new(x + 5, 3, 0), "VentCrawling", time)
		t.eq(kind, nil, "the entry jump is silent")
		t.eq(track.medium, "Vent")
		local crawl = walk(track, "VentCrawling", GameConfig.VentCrawlSpeed, time + TICK, 2, x + 5)
		t.truthy(#crawl >= 1, "crawling is heard")
		for _, pulse in crawl do
			t.eq(pulse.kind, "SlowVentCrawl")
		end
		assertSpacing(t, crawl, "vent crawl")
	end,

	["intervalElapsed paces continuous kinds and never one-shots"] = function(t: Expect)
		local walkInterval = NoiseConfig.Kinds.Walk.interval
		t.truthy(Sampler.intervalElapsed(nil, 0, "Walk", 0), "first pulse")
		t.falsy(Sampler.intervalElapsed(10, 10 + walkInterval / 2, "Walk", 0), "too soon")
		t.truthy(Sampler.intervalElapsed(10, 10 + walkInterval, "Walk", 0), "exactly the interval")
		t.truthy(Sampler.intervalElapsed(10, 10 + walkInterval - 0.04, "Walk", 0.05), "within the slack")
		t.truthy(Sampler.intervalElapsed(10, 10, "GrateKick", 0), "one-shot kinds are never paced")
	end,

	--------------------------------------------------------------------------------
	-- Floor debris (injected dependencies)
	--------------------------------------------------------------------------------

	["floor debris crunches once per player and volume per cooldown, only in a run"] = function(t: Expect)
		local now = 100
		local running = true
		local emitted: { { position: Vector3, kind: Enums.NoiseKind, options: Sampler.EmitOptions } } = {}
		local cues: { string } = {}
		local roots: { [Player]: Vector3 } = {}
		local debris = DebrisNoise.new({
			inRun = function(): boolean
				return running
			end,
			now = function(): number
				return now
			end,
			positionOf = function(player: Player, _volume: BasePart): Vector3?
				return roots[player]
			end,
			emit = function(position: Vector3, kind: Enums.NoiseKind, options: Sampler.EmitOptions)
				table.insert(emitted, { position = position, kind = kind, options = options })
			end,
			playCue = function(preset: string, _position: Vector3)
				table.insert(cues, preset)
			end,
		})
		local alice, bob = fakePlayer(9101), fakePlayer(9102)
		roots[alice] = Vector3.new(1, 2, 3)
		roots[bob] = Vector3.new(4, 5, 6)
		local glass = Instance.new("Part")
		glass:SetAttribute("LevelId", "Level2_Auditorium")
		local cans = Instance.new("Part")

		t.truthy(debris.onVolumeEntered(alice, glass, Tags.FloorDebris), "first entry crunches")
		t.eq(#emitted, 1)
		t.eq(emitted[1].kind, "FloorDebris")
		t.eq(NoiseConfig.Kinds.FloorDebris.radius, 130, "the spec's 130-stud debris noise")
		t.eq(emitted[1].position, roots[alice], "where the player stands")
		t.eq(emitted[1].options.sourcePlayer, alice)
		t.eq(emitted[1].options.levelId, "Level2_Auditorium", "the volume's level")
		t.eq(cues[1], "GlassCrunch")

		now += DebrisNoise.Cooldown / 2
		t.falsy(debris.onVolumeEntered(alice, glass, Tags.FloorDebris), "same volume inside the cooldown")
		t.truthy(debris.onVolumeEntered(alice, cans, Tags.FloorDebris), "another volume crunches at once")
		t.eq(emitted[2].options.levelId, nil, "a volume without a level leaves it to Emit")
		t.truthy(debris.onVolumeEntered(bob, glass, Tags.FloorDebris), "cooldowns are per player")
		t.falsy(debris.onVolumeEntered(alice, glass, Tags.ScareTrigger), "other trigger tags are not debris")

		now += DebrisNoise.Cooldown
		t.truthy(debris.onVolumeEntered(alice, glass, Tags.FloorDebris), "crunches again after the cooldown")

		roots[alice] = nil
		now += DebrisNoise.Cooldown * 2
		t.falsy(debris.onVolumeEntered(alice, glass, Tags.FloorDebris), "no living character, no crunch")

		running = false
		roots[alice] = Vector3.zero
		t.falsy(debris.onVolumeEntered(alice, cans, Tags.FloorDebris), "outside a run nothing is heard")
		running = true
		debris.reset()
		t.truthy(debris.onVolumeEntered(bob, glass, Tags.FloorDebris), "reset clears every cooldown")
		debris.forget(bob)
		t.truthy(debris.onVolumeEntered(bob, glass, Tags.FloorDebris), "forget clears a player's cooldowns")
		t.eq(#emitted, #cues, "every crunch is heard and played")
		glass:Destroy()
		cans:Destroy()
	end,
}
