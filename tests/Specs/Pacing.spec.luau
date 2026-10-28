--!strict
-- PacingDirector, driven by a fake clock (server time advanced by hand alongside each Tick). Tension rises with
-- chases, sightings and near misses, decays when quiet and stays in [0, 1]. BuildUp -> Peak needs high tension and a
-- player near; Peak -> Relax on a catch, the leash, PeakMaxSeconds or the players getting away; Relax holds (no
-- hunting, quieter ears) for RelaxSeconds and past the catch cooldown, then BuildUp with tension capped. The catch
-- cooldown and airlock grace come from DifficultyConfig; ShouldBreakChase is the leash (sooner in Relax); HearingScale
-- is quieter in Relax and sharper at Peak. Properties over random play: it never hunts during a cooldown, a grace or
-- Relax; a catch always relaxes it and it always comes back to BuildUp; no Peak outlasts PeakMaxSeconds and no chase
-- outlasts the leash outside Relax. repositionPoint: inside the band, out of sight, nearest to `from` first, checked
-- against brute force.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)

local PacingDirector = require(ServerScriptService.Services.Core.NoiseAndDirectorService.PacingDirector)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect
type Pacing = PacingDirector.Pacing
type PacingInput = PacingDirector.PacingInput

local DT = 0.1 -- the brain's 10 Hz tick
local START = 5000
local EPS = 1e-6
local DIFFICULTIES: { Enums.Difficulty } = { "Standard", "Nightmare" }

local QUIET: PacingInput = { chasing = false, seesTarget = false, nearestPlayerDistance = nil }
local HOT: PacingInput = { chasing = true, seesTarget = true, nearestPlayerDistance = 6 }

-- A Pacing plus the server time it lives at.
type Run = { pacing: Pacing, now: number }

local function newRun(difficulty: Enums.Difficulty): Run
	return { pacing = PacingDirector.new(difficulty, START), now = START }
end

-- Ticks for `seconds` of play with `input` (the clock moves with every tick); returns the phase at the end.
local function play(run: Run, seconds: number, input: PacingInput): PacingDirector.PacingPhase
	local phase: PacingDirector.PacingPhase = run.pacing:GetPhase()
	for _ = 1, math.round(seconds / DT) do
		run.now += DT
		phase = run.pacing:Tick(DT, input)
	end
	return phase
end

-- Ticks until `phase` (true) or `limit` seconds pass (false).
local function playUntil(run: Run, phase: PacingDirector.PacingPhase, limit: number, input: PacingInput): boolean
	for _ = 1, math.round(limit / DT) do
		run.now += DT
		if run.pacing:Tick(DT, input) == phase then
			return true
		end
	end
	return false
end

local function tension(run: Run): number
	return run.pacing:Snapshot().tension
end

-- Drives a fresh run into Peak with a close, sighted chase.
local function toPeak(t: Expect, run: Run)
	t.truthy(playUntil(run, "Peak", 60, HOT), "a close chase in sight peaks")
end

local function randomInput(random: Random): PacingInput
	local roll = random:NextNumber()
	if roll < 0.35 then
		return QUIET
	end
	return {
		chasing = random:NextNumber() < 0.6,
		seesTarget = random:NextNumber() < 0.5,
		nearestPlayerDistance = if random:NextNumber() < 0.2 then nil else random:NextNumber(0, 90),
	}
end

local function spec(difficulty: Enums.Difficulty): DifficultyConfig.DifficultySpec
	return if difficulty == "Nightmare" then DifficultyConfig.Nightmare else DifficultyConfig.Standard
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["new: BuildUp at zero tension, free to hunt, no cooldown or grace running"] = function(t: Expect)
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local pacing = PacingDirector.new(difficulty, START)
			local snapshot = pacing:Snapshot()
			t.eq(pacing:GetPhase(), "BuildUp", "phase")
			t.eq(snapshot.phase, "BuildUp", "snapshot phase")
			t.eq(snapshot.tension, 0, "tension")
			t.truthy(snapshot.cooldownUntil <= START and snapshot.graceUntil <= START, "nothing running")
			t.truthy(pacing:CanHunt(START), "free to hunt")
			t.eq(pacing:HearingScale(), 1, "plain ears")
		end
	end,

	["tension: chases, sightings and near misses raise it; quiet decays it; always within [0, 1]"] = function(
		t: Expect
	)
		local tuning = PacingDirector.tuning("Standard")
		local chase = newRun("Standard")
		play(chase, 5, { chasing = true, seesTarget = false, nearestPlayerDistance = 60 })
		local chased = tension(chase)
		t.near(chased, (tuning.ChaseRise - tuning.Decay) * 5, 1e-3, "a far chase")

		local sight = newRun("Standard")
		play(sight, 5, { chasing = true, seesTarget = true, nearestPlayerDistance = 60 })
		t.truthy(tension(sight) > chased, "seeing the target adds to it")

		local brush = newRun("Standard")
		play(brush, 5, { chasing = false, seesTarget = false, nearestPlayerDistance = 1 })
		t.truthy(tension(brush) > 0, "a near miss (passing a locker) raises it with no chase at all")
		local closer = newRun("Standard")
		play(closer, 5, { chasing = false, seesTarget = false, nearestPlayerDistance = 0 })
		t.truthy(tension(closer) > tension(brush), "closer is tenser")
		t.eq(PacingDirector.nearMissRise(tuning, tuning.NearMissDistance), 0, "nothing at the edge")
		t.eq(PacingDirector.nearMissRise(tuning, nil), 0, "nothing when nobody is around")
		t.near(PacingDirector.nearMissRise(tuning, 0), tuning.NearMissRise, EPS, "full at contact")

		local before = tension(sight)
		play(sight, 4, QUIET)
		t.truthy(tension(sight) < before, "quiet decays it")
		play(sight, 600, QUIET)
		t.eq(tension(sight), 0, "down to zero, no lower")

		local maxed = newRun("Nightmare")
		play(maxed, 300, HOT)
		t.truthy(tension(maxed) <= 1 and tension(maxed) >= 0, "never above 1")
	end,

	["BuildUp -> Peak needs high tension and a player near"] = function(t: Expect)
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local tuning = PacingDirector.tuning(difficulty)
			local far = newRun(difficulty)
			local farChase: PacingInput =
				{ chasing = true, seesTarget = true, nearestPlayerDistance = tuning.PeakProximity + 5 }
			t.falsy(
				playUntil(far, "Peak", tuning.MaxChaseSeconds - 1, farChase),
				difficulty .. ": nobody near, no Peak"
			)
			t.truthy(tension(far) >= tuning.PeakEnter, difficulty .. ": even with the tension there")

			local run = newRun(difficulty)
			toPeak(t, run)
			t.truthy(tension(run) >= tuning.PeakEnter, difficulty .. ": peaked at PeakEnter")
			t.eq(run.pacing:HearingScale(), tuning.HearingScale.Peak, "sharper ears at Peak")
			t.truthy(run.pacing:CanHunt(run.now), "Peak hunts")
		end
	end,

	["Peak -> Relax: a catch, the leash, PeakMaxSeconds, or the players getting away"] = function(t: Expect)
		local tuning = PacingDirector.tuning("Standard")

		local caught = newRun("Standard")
		toPeak(t, caught)
		caught.pacing:NoteCatch(caught.now)
		t.eq(caught.pacing:GetPhase(), "Relax", "a catch")
		t.eq(tension(caught), 1, "the catch is the climax")

		local leashed = newRun("Standard")
		toPeak(t, leashed)
		t.truthy(playUntil(leashed, "Relax", tuning.MaxChaseSeconds + 1, HOT), "the leash")

		local lingering = newRun("Standard")
		toPeak(t, lingering)
		local stalk: PacingInput = { chasing = false, seesTarget = true, nearestPlayerDistance = 5 }
		local stayed = 0
		while lingering.pacing:GetPhase() == "Peak" and stayed < tuning.PeakMaxSeconds + 5 do
			play(lingering, DT, stalk)
			stayed += DT
		end
		t.eq(lingering.pacing:GetPhase(), "Relax", "a Peak that drags on")
		t.truthy(stayed <= tuning.PeakMaxSeconds + DT + EPS, "after PeakMaxSeconds: " .. stayed)

		local escaped = newRun("Standard")
		toPeak(t, escaped)
		local lost = 0
		while escaped.pacing:GetPhase() == "Peak" and lost < tuning.PeakMaxSeconds do
			play(escaped, DT, QUIET)
			lost += DT
		end
		t.eq(escaped.pacing:GetPhase(), "Relax", "the players got away")
		t.truthy(lost < tuning.PeakMaxSeconds - 1, "before PeakMaxSeconds (tension fell): " .. lost)
		t.truthy(tension(escaped) <= tuning.PeakExit + EPS, "at PeakExit")
	end,

	["Relax: no hunting, quieter ears, then BuildUp after RelaxSeconds with tension capped"] = function(t: Expect)
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local tuning = PacingDirector.tuning(difficulty)
			local run = newRun(difficulty)
			toPeak(t, run)
			run.pacing:NoteCatch(run.now)
			local caughtAt = run.now
			t.eq(run.pacing:HearingScale(), tuning.HearingScale.Relax, "quieter ears")
			t.truthy(tuning.HearingScale.Relax < tuning.HearingScale.BuildUp, "Relax < BuildUp")
			t.truthy(tuning.HearingScale.BuildUp < tuning.HearingScale.Peak, "BuildUp < Peak")
			local hold = math.max(tuning.RelaxSeconds, tuning.CatchCooldownSeconds)
			while run.pacing:GetPhase() == "Relax" do
				t.falsy(run.pacing:CanHunt(run.now), difficulty .. ": no hunting in Relax")
				play(run, DT, HOT)
				t.truthy(run.now - caughtAt <= hold + DT + EPS, difficulty .. ": Relax ends on time")
			end
			t.truthy(run.now - caughtAt >= hold - EPS, difficulty .. ": Relax holds " .. hold .. "s")
			t.eq(run.pacing:GetPhase(), "BuildUp", "then BuildUp")
			t.truthy(tension(run) <= tuning.RelaxExitTension + EPS, "the next peak has to be built again")
			t.truthy(run.pacing:CanHunt(run.now), "hunting again")
		end
	end,

	["catch cooldown = DifficultyConfig.catchCooldownSeconds; grace = postAirlockGraceSeconds"] = function(t: Expect)
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local tuning = PacingDirector.tuning(difficulty)
			t.eq(tuning.CatchCooldownSeconds, spec(difficulty).catchCooldownSeconds, "cooldown from config")
			t.eq(tuning.AirlockGraceSeconds, spec(difficulty).postAirlockGraceSeconds, "grace from config")
			t.eq(tuning.MaxChaseSeconds, spec(difficulty).maxChaseSeconds, "leash from config")

			local run = newRun(difficulty)
			play(run, 3, QUIET)
			run.pacing:NoteCatch(run.now)
			t.near(run.pacing:Snapshot().cooldownUntil, run.now + spec(difficulty).catchCooldownSeconds, EPS, "until")

			local level = newRun(difficulty)
			play(level, 2, HOT)
			level.pacing:NoteAirlock(level.now)
			local graceUntil = level.now + spec(difficulty).postAirlockGraceSeconds
			t.near(level.pacing:Snapshot().graceUntil, graceUntil, EPS, "grace until")
			t.eq(level.pacing:GetPhase(), "BuildUp", "a new level starts in BuildUp")
			t.truthy(tension(level) <= tuning.AirlockTension + EPS, "calm")
			while level.now < graceUntil - EPS do
				t.falsy(level.pacing:CanHunt(level.now), difficulty .. ": no hunting in the grace")
				play(level, DT, QUIET)
			end
			play(level, DT, QUIET)
			t.truthy(level.pacing:CanHunt(level.now), difficulty .. ": hunting once the grace is over")
		end
	end,

	["ShouldBreakChase: the leash at maxChaseSeconds, RelaxChaseSeconds while relaxing"] = function(t: Expect)
		for _, difficulty: Enums.Difficulty in DIFFICULTIES do
			local tuning = PacingDirector.tuning(difficulty)
			local leash = spec(difficulty).maxChaseSeconds
			local run = newRun(difficulty)
			t.falsy(run.pacing:ShouldBreakChase(leash - 0.1), "BuildUp: under the leash")
			t.truthy(run.pacing:ShouldBreakChase(leash), "BuildUp: at the leash")
			toPeak(t, run)
			t.falsy(run.pacing:ShouldBreakChase(tuning.RelaxChaseSeconds + 1), "Peak: a short chase goes on")
			t.truthy(run.pacing:ShouldBreakChase(leash + 5), "Peak: past the leash")
			run.pacing:NoteCatch(run.now)
			t.falsy(run.pacing:ShouldBreakChase(tuning.RelaxChaseSeconds - 0.1), "Relax: a moment's grace")
			t.truthy(run.pacing:ShouldBreakChase(tuning.RelaxChaseSeconds), "Relax forces the break early")
			t.falsy(run.pacing:ShouldBreakChase(0 / 0), "NaN is no reason to break")
		end
	end,

	["property: never hunts during a cooldown, a grace or Relax"] = function(t: Expect)
		local random = Random.new(2027)
		for trial = 1, 40 do
			local difficulty: Enums.Difficulty = DIFFICULTIES[random:NextInteger(1, 2)]
			local run = newRun(difficulty)
			for _ = 1, 1500 do
				local roll = random:NextNumber()
				if roll < 0.004 then
					run.pacing:NoteCatch(run.now)
				elseif roll < 0.006 then
					run.pacing:NoteAirlock(run.now)
				end
				local input = randomInput(random)
				for _ = 1, random:NextInteger(1, 8) do
					run.now += DT
					run.pacing:Tick(DT, input)
				end
				local snapshot = run.pacing:Snapshot()
				local blocked = run.now < snapshot.cooldownUntil
					or run.now < snapshot.graceUntil
					or snapshot.phase == "Relax"
				if blocked then
					t.falsy(run.pacing:CanHunt(run.now), "trial " .. trial .. ": hunting while it must not")
				else
					t.truthy(run.pacing:CanHunt(run.now), "trial " .. trial .. ": held back for no reason")
				end
				t.truthy(snapshot.tension >= 0 and snapshot.tension <= 1, "tension in range")
			end
		end
	end,

	["property: a catch always relaxes it, and it always comes back to BuildUp"] = function(t: Expect)
		local random = Random.new(404)
		for trial = 1, 60 do
			local difficulty: Enums.Difficulty = DIFFICULTIES[random:NextInteger(1, 2)]
			local tuning = PacingDirector.tuning(difficulty)
			local run = newRun(difficulty)
			for _ = 1, random:NextInteger(0, 400) do
				play(run, DT, randomInput(random))
			end
			run.pacing:NoteCatch(run.now)
			t.eq(run.pacing:GetPhase(), "Relax", "trial " .. trial .. ": relaxed at once")
			local bound = math.max(tuning.RelaxSeconds, tuning.CatchCooldownSeconds) + 2 * DT
			local elapsed = 0
			while run.pacing:GetPhase() == "Relax" and elapsed <= bound do
				t.falsy(run.pacing:CanHunt(run.now), "trial " .. trial .. ": no hunting while relaxed")
				play(run, DT, randomInput(random))
				elapsed += DT
			end
			t.eq(run.pacing:GetPhase(), "BuildUp", "trial " .. trial .. ": back to BuildUp within " .. bound .. "s")
		end
	end,

	["property: no Peak outlasts PeakMaxSeconds; no chase outlasts the leash outside Relax"] = function(t: Expect)
		local random = Random.new(88)
		for trial = 1, 30 do
			local difficulty: Enums.Difficulty = DIFFICULTIES[random:NextInteger(1, 2)]
			local tuning = PacingDirector.tuning(difficulty)
			local run = newRun(difficulty)
			local inPeak, chasing = 0, 0
			for _ = 1, 4000 do
				local input = if random:NextNumber() < 0.7 then HOT else randomInput(random)
				local phase = play(run, DT, input)
				inPeak = if phase == "Peak" then inPeak + DT else 0
				chasing = if input.chasing then chasing + DT else 0
				t.truthy(inPeak <= tuning.PeakMaxSeconds + DT + EPS, "trial " .. trial .. ": Peak too long")
				if phase ~= "Relax" and chasing > tuning.MaxChaseSeconds + DT + EPS then
					t.fail("trial " .. trial .. ": a chase ran past the leash without a Relax")
				end
				if phase == "Relax" then
					chasing = 0
				end
			end
		end
	end,

	["non-finite input never corrupts the state"] = function(t: Expect)
		local run = newRun("Standard")
		run.pacing:Tick(0 / 0, HOT)
		run.pacing:Tick(math.huge, HOT)
		run.pacing:Tick(-5, HOT)
		run.pacing:Tick(DT, { chasing = false, seesTarget = false, nearestPlayerDistance = 0 / 0 })
		run.pacing:NoteCatch(0 / 0)
		local snapshot = run.pacing:Snapshot()
		t.truthy(snapshot.tension == snapshot.tension, "tension is a number")
		t.truthy(snapshot.cooldownUntil == snapshot.cooldownUntil, "cooldown is a number")
		t.eq(snapshot.phase, "Relax", "the catch still counts")
		t.falsy(run.pacing:CanHunt(0 / 0), "no hunting in Relax, whatever the clock says")
	end,

	["repositionPoint: inside the band, out of sight, nearest to `from` first"] = function(t: Expect)
		local candidates = {
			Vector3.new(0, 0, 10), -- 1: nearest to `from`, but too close to the player
			Vector3.new(0, 0, 40), -- 2: in the band, but seen
			Vector3.new(30, 0, 30), -- 3: in the band, hidden
			Vector3.new(-45, 0, 10), -- 4: in the band, hidden, farther from `from`
			Vector3.new(0, 0, 300), -- 5: far beyond the band
		}
		local players = { Vector3.new(0, 0, 0) }
		local from = Vector3.new(0, 0, 12)
		local asked: { Vector3 } = {}
		local seen: { [Vector3]: boolean } = { [candidates[2]] = true }
		local function visible(point: Vector3): boolean
			table.insert(asked, point)
			return seen[point] == true
		end
		local chosen = PacingDirector.repositionPoint(candidates, players, from, 25, 80, visible)
		t.eq(chosen, candidates[3], "the nearest hidden point inside the band")
		t.eq(#asked, 2, "sight is checked nearest first and only until one passes")
		t.eq(asked[1], candidates[2], "the nearer in-band point is checked first")

		t.eq(
			PacingDirector.repositionPoint(candidates, players, from, 25, 80, function(_: Vector3): boolean
				return true
			end),
			nil,
			"nil when every point in the band is seen"
		)
		t.eq(PacingDirector.repositionPoint({}, players, from, 25, 80, visible), nil, "nil with no candidates")
		local anywhere = PacingDirector.repositionPoint(candidates, {}, from, 25, 80, function(_: Vector3): boolean
			return false
		end)
		t.eq(anywhere, candidates[1], "no players: the nearest hidden point")

		local random = Random.new(9)
		for trial = 1, 150 do
			local points: { Vector3 } = {}
			for _ = 1, random:NextInteger(0, 14) do
				table.insert(points, Vector3.new(random:NextNumber(-100, 100), 0, random:NextNumber(-100, 100)))
			end
			local squad: { Vector3 } = {}
			for _ = 1, random:NextInteger(1, 4) do
				table.insert(squad, Vector3.new(random:NextNumber(-60, 60), 0, random:NextNumber(-60, 60)))
			end
			local origin = Vector3.new(random:NextNumber(-60, 60), 0, random:NextNumber(-60, 60))
			local minimum = random:NextNumber(5, 30)
			local maximum = minimum + random:NextNumber(10, 80)
			local hidden: { [Vector3]: boolean } = {}
			for _, point in points do
				hidden[point] = random:NextNumber() < 0.5
			end
			local function sees(point: Vector3): boolean
				return not hidden[point]
			end
			local best: Vector3? = nil
			local bestDistance = math.huge
			for _, point in points do
				local nearest = math.huge
				for _, player in squad do
					nearest = math.min(nearest, (point - player).Magnitude)
				end
				local distance = (point - origin).Magnitude
				if nearest >= minimum and nearest <= maximum and hidden[point] and distance < bestDistance then
					best, bestDistance = point, distance
				end
			end
			local got = PacingDirector.repositionPoint(points, squad, origin, minimum, maximum, sees)
			t.eq(got, best, "trial " .. trial .. ": matches brute force")
		end
	end,
}
