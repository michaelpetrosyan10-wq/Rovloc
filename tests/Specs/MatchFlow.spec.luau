--!strict
-- MatchFlow. The match policy on a fake clock with every dependency injected: the evaluator's verdict table, rewards
-- (per floor, the escape bonus, Escapes, BestTime per difficulty, LastRunId idempotence, the cap), the deploy squad,
-- Deploy (perk stock consumed, unstocked perks dropped from the loadout, refusals, Level 0 spawn slots), a wipe
-- (coalesced evaluation, RunEnded -> rewards -> RunSummary -> RunResolved -> Results), an escape waiting for the rest of
-- the squad, a downed player with a syringe keeping the run alive, a leaver settled as they go, DevRun and guest runs
-- paying nothing; MatchResetService (the Results clock with the escape finale, everyone pressing Play Again, a leaver,
-- spectators' presses, PlayAgainRequested back in the Lobby); TelemetryService's events (funnel order, deaths, floors
-- reached, the economy from commits).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Types = require(ReplicatedStorage.Shared.Types)

local MatchFolder = ServerScriptService.Services.Match
local MatchAndDataService = require(MatchFolder.MatchAndDataService)
local MatchResetService = require(MatchFolder.MatchResetService)
local TelemetryService = require(MatchFolder.TelemetryService)
local DataMigration = require(MatchFolder.MatchAndDataService.DataMigration)
local PlayerDataStore = require(MatchFolder.MatchAndDataService.PlayerDataStore)
local StoreBackend = require(MatchFolder.MatchAndDataService.StoreBackend)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

type Sent = { remote: string, player: Player, payload: any }

type World = {
	now: number,
	wall: number,
	phase: Enums.MatchPhase,
	phases: { Enums.MatchPhase },
	run: Types.RunContext?,
	life: { [Player]: Enums.LifeState },
	syringe: { [Player]: number },
	floors: { [Player]: number },
	stats: { [Player]: { [string]: number } },
	gone: { [Player]: boolean },
	devRun: boolean,
	sent: { Sent },
	loadouts: { [Player]: { Enums.PerkId } },
	spawned: { { player: Player, slot: number } },
	deferred: { () -> () },
	runs: number,
	store: PlayerDataStore.Store,
	backend: StoreBackend.Backend,
}

local P = Attributes.Player

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local nextUserId = 9100

local function newPlayer(): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = "FlowSpec" .. nextUserId
	local writable = player :: any
	writable.UserId = nextUserId
	return player
end

local function flush(world: World)
	while #world.deferred > 0 do
		local fn = table.remove(world.deferred, 1)
		if fn then
			fn()
		end
	end
end

local function newWorld(): World
	local backend = StoreBackend.ephemeral()
	local world = {} :: World
	world.now = 100
	world.wall = 1_700_000_000
	world.phase = "Lobby"
	world.phases = {}
	world.run = nil
	world.life = {}
	world.syringe = {}
	world.floors = {}
	world.stats = {}
	world.gone = {}
	world.devRun = false
	world.sent = {}
	world.loadouts = {}
	world.spawned = {}
	world.deferred = {}
	world.runs = 0
	world.backend = backend
	world.store = PlayerDataStore.new({
		backend = backend,
		sessionId = "flow-spec",
		now = function(): number
			return world.wall
		end,
		wait = function(seconds: number)
			world.wall += seconds
		end,
	})
	MatchAndDataService.SetDependencies({
		store = world.store,
		now = function(): number
			return world.now
		end,
		phase = function(): Enums.MatchPhase
			return world.phase
		end,
		setPhase = function(phase: Enums.MatchPhase): boolean
			table.insert(world.phases, phase)
			world.phase = phase
			return true
		end,
		run = function(): Types.RunContext?
			return world.run
		end,
		beginRun = function(participants: { Player }, difficulty: Enums.Difficulty): Types.RunContext
			world.runs += 1
			local ctx: Types.RunContext = {
				runId = string.format("00000000-0000-4000-8000-%012d", world.runs),
				seed = world.runs,
				difficulty = difficulty,
				participants = table.clone(participants),
				startedAt = world.now,
			}
			world.run = ctx
			for _, player in participants do
				world.life[player] = "Alive"
				world.stats[player] = {}
			end
			MatchAndDataService.BeginRun(ctx)
			world.phase = "InRun"
			return ctx
		end,
		lifeState = function(player: Player): Enums.LifeState
			return world.life[player] or "Lobby"
		end,
		syringeCharges = function(player: Player): number
			return world.syringe[player] or 0
		end,
		floorsCleared = function(player: Player): number
			return world.floors[player] or 0
		end,
		stats = function(player: Player): { [string]: number }
			local snapshot: { [string]: number } = {}
			for _, key: Enums.StatKey in Enums.StatKey do
				snapshot[key] = (world.stats[player] or {})[key] or 0
			end
			return snapshot
		end,
		addStat = function(player: Player, key: Enums.StatKey, amount: number)
			local entry = world.stats[player] or {}
			world.stats[player] = entry
			entry[key] = (entry[key] or 0) + amount
		end,
		runSeconds = function(): number
			local run = world.run
			return if run then world.now - run.startedAt else 0
		end,
		devRun = function(): boolean
			return world.devRun
		end,
		present = function(player: Player): boolean
			return not world.gone[player]
		end,
		send = function(remote: string, player: Player, payload: any)
			table.insert(world.sent, { remote = remote, player = player, payload = payload })
		end,
		setLoadout = function(player: Player, perks: { Enums.PerkId })
			world.loadouts[player] = perks
		end,
		spawn = function(players: { Player })
			for slot, player in players do
				table.insert(world.spawned, { player = player, slot = slot })
			end
		end,
		defer = function(fn: () -> ())
			table.insert(world.deferred, fn)
		end,
	})
	return world
end

-- A player with loaded data (credits / stock as given).
local function join(world: World, credits: number?, stock: { [string]: number }?): Player
	local player = newPlayer()
	if credits or stock then
		world.backend.update(PlayerDataStore.KeyPrefix .. tostring(player.UserId), function(): unknown
			return { data = { v = 1, SurvivalCredits = credits or 0, PerkStock = stock or {} }, savedAt = world.wall }
		end)
	end
	MatchAndDataService.OnPlayerAdded(player)
	assert(MatchAndDataService.GetData(player), "the spec store loads inline")
	return player
end

local function finish(world: World, players: { Player })
	MatchAndDataService.EndRun()
	for _, player in players do
		MatchAndDataService.OnPlayerRemoving(player)
	end
	world.run = nil
	MatchAndDataService.SetDependencies(nil)
end

local function summaries(world: World, player: Player): { Types.RunSummaryPayload }
	local out: { Types.RunSummaryPayload } = {}
	for _, entry in world.sent do
		if entry.remote == "RunSummary" and entry.player == player then
			table.insert(out, entry.payload :: Types.RunSummaryPayload)
		end
	end
	return out
end

local function credits(player: Player): number
	local data = MatchAndDataService.GetData(player)
	return if data then data.SurvivalCredits else -1
end

local function standing(lifeState: Enums.LifeState, syringe: number?): MatchAndDataService.Standing
	return { escaped = false, disconnected = false, lifeState = lifeState, syringeCharges = syringe or 0 }
end

--------------------------------------------------------------------------------
-- Pure rules
--------------------------------------------------------------------------------

local spec = {}

spec["verdict: who keeps a run going"] = function(t: Expect)
	local verdict = MatchAndDataService.verdict
	t.eq(verdict({}), "Continue", "an empty run is never judged")
	t.eq(verdict({ standing("Alive"), standing("Dead") }), "Continue")
	t.eq(verdict({ standing("Dead"), standing("Spectating") }), "Wipe")
	t.eq(verdict({ standing("Downed", 0), standing("Dead") }), "Wipe", "a downed player nobody can revive")
	t.eq(verdict({ standing("Downed", 1), standing("Dead") }), "Continue", "a syringe can still save the run")
	t.eq(verdict({ standing("Downed", 0), standing("Alive") }), "Continue", "a teammate can revive")
	local escaped: MatchAndDataService.Standing =
		{ escaped = true, disconnected = false, lifeState = "Alive", syringeCharges = 0 }
	local gone: MatchAndDataService.Standing =
		{ escaped = false, disconnected = true, lifeState = "Lobby", syringeCharges = 0 }
	t.eq(verdict({ escaped, standing("Alive") }), "Continue", "the squad waits for the last runner")
	t.eq(verdict({ escaped, standing("Dead") }), "Escape")
	t.eq(verdict({ escaped, gone }), "Escape")
	t.eq(verdict({ gone, gone }), "Wipe", "everyone left")
	t.eq(verdict({ escaped }), "Escape")
end

spec["rewards: floors, the escape bonus, best times and LastRunId"] = function(t: Expect)
	t.eq(MatchAndDataService.rewardFor(false, 0), 0)
	t.eq(MatchAndDataService.rewardFor(false, 3), 3 * GameConfig.CreditsPerLevelCleared)
	t.eq(MatchAndDataService.rewardFor(true, 5), 5 * GameConfig.CreditsPerLevelCleared + GameConfig.CreditsEscapeBonus)
	t.eq(MatchAndDataService.rewardFor(false, -2), 0)

	local data = DataMigration.defaults()
	local first = MatchAndDataService.applyReward(data, {
		runId = "run-1",
		credits = 120,
		escaped = true,
		difficulty = "Standard",
		time = 600.123,
	})
	t.truthy(first.applied)
	t.truthy(first.newBest)
	t.eq(data.SurvivalCredits, 120)
	t.eq(data.Escapes, 1)
	t.eq(data.BestTime.Standard, 600.12, "kept to the hundredth")
	t.eq(data.LastRunId, "run-1")
	local again = MatchAndDataService.applyReward(data, {
		runId = "run-1",
		credits = 120,
		escaped = true,
		difficulty = "Standard",
		time = 1,
	})
	t.falsy(again.applied, "the same run never pays twice")
	t.eq(data.SurvivalCredits, 120)
	t.eq(data.Escapes, 1)
	local slower = MatchAndDataService.applyReward(data, {
		runId = "run-2",
		credits = 100,
		escaped = true,
		difficulty = "Standard",
		time = 700,
	})
	t.truthy(slower.applied)
	t.falsy(slower.newBest)
	t.eq(data.BestTime.Standard, 600.12, "a slower escape keeps the best")
	local nightmare = MatchAndDataService.applyReward(data, {
		runId = "run-3",
		credits = 0,
		escaped = true,
		difficulty = "Nightmare",
		time = 900,
	})
	t.truthy(nightmare.newBest, "best times are per difficulty")
	t.eq(data.BestTime.Nightmare, 900)
	local died = MatchAndDataService.applyReward(data, {
		runId = "run-4",
		credits = 40,
		escaped = false,
		difficulty = "Standard",
		time = nil,
	})
	t.truthy(died.applied)
	t.eq(data.Escapes, 3, "dying is no escape")
	t.eq(data.SurvivalCredits, 260)
	t.eq(DataMigration.validate(data), nil)
	local capped = DataMigration.defaults()
	capped.SurvivalCredits = DataMigration.MaxCredits - 5
	MatchAndDataService.applyReward(capped, {
		runId = "run-5",
		credits = 100,
		escaped = false,
		difficulty = "Standard",
		time = nil,
	})
	t.eq(capped.SurvivalCredits, DataMigration.MaxCredits)
end

spec["squadFrom: present players, once each, capped"] = function(t: Expect)
	local a, b, c, d, e = newPlayer(), newPlayer(), newPlayer(), newPlayer(), newPlayer()
	local away: { [Player]: boolean } = { [b] = true }
	local squad = MatchAndDataService.squadFrom({ a, b, a, c, d, e, newPlayer() }, function(player: Player): boolean
		return not away[player]
	end)
	t.eq(#squad, math.min(GameConfig.MaxSquad, 4))
	t.eq(squad[1], a)
	t.eq(squad[2], c, "absent players are skipped, duplicates kept once")
	t.eq(table.find(squad, b), nil)
end

--------------------------------------------------------------------------------
-- Deploy and resolution
--------------------------------------------------------------------------------

spec["Deploy: consumes stock, drops unstocked perks, spawns, refuses a second run"] = function(t: Expect)
	local world = newWorld()
	local stocked = join(world, 0, { RustyScrewdriver = 2, AdrenalineSyringe = 1 })
	local empty = join(world, 0, {})
	stocked:SetAttribute(P.Loadout, "RustyScrewdriver,LithiumCell,AdrenalineSyringe")
	empty:SetAttribute(P.Loadout, "LithiumCell")
	world.phase = "Countdown"
	t.falsy(MatchAndDataService.Deploy({}, "Standard"), "nobody to send")
	t.truthy(MatchAndDataService.Deploy({ stocked, empty, stocked }, "Nightmare"))
	local run = world.run
	t.truthy(run and #run.participants == 2 and run.difficulty == "Nightmare")
	local data = MatchAndDataService.GetData(stocked)
	t.eq(data and data.PerkStock.RustyScrewdriver, 1, "one unit consumed")
	t.eq(data and data.PerkStock.AdrenalineSyringe, 0, "the last unit consumed")
	local trimmed = world.loadouts[stocked]
	t.truthy(trimmed and #trimmed == 2 and table.find(trimmed, "LithiumCell") == nil, "the unstocked perk is dropped")
	local none = world.loadouts[empty]
	t.truthy(none and #none == 0)
	t.eq(#world.spawned, 2)
	t.eq(world.spawned[1].player, stocked)
	t.eq(world.spawned[1].slot, 1)
	t.eq(world.spawned[2].slot, 2)
	t.eq(stocked:GetAttribute(P.RunOutcome), "Pending")
	t.eq(MatchAndDataService.GetOutcome(stocked), "Pending")
	t.falsy(MatchAndDataService.Deploy({ empty }, "Standard"), "a run is already in progress")
	world.run = nil
	world.phase = "Results"
	t.falsy(MatchAndDataService.Deploy({ empty }, "Standard"), "only from the lobby")
	finish(world, { stocked, empty })
end

spec["Wipe: coalesced evaluation, floor credits, summary, RunResolved, Results"] = function(t: Expect)
	local world = newWorld()
	local a = join(world)
	local b = join(world)
	MatchAndDataService.Deploy({ a, b }, "Standard")
	local resolvedWith: { { [Player]: Enums.RunOutcome } } = {}
	local connection = MatchAndDataService.RunResolved:Connect(function(outcomes: { [Player]: Enums.RunOutcome })
		table.insert(resolvedWith, outcomes)
	end)
	world.floors[a] = 2
	world.floors[b] = 1
	world.now += 300
	world.life[a] = "Dead"
	MatchAndDataService.RequestEvaluation()
	MatchAndDataService.RequestEvaluation()
	t.eq(#world.deferred, 1, "evaluations in one frame coalesce")
	flush(world)
	t.eq(#resolvedWith, 0, "a teammate is still alive")
	world.life[b] = "Downed"
	MatchAndDataService.RequestEvaluation()
	flush(world)
	t.eq(#resolvedWith, 1, "nobody can revive the last one: wiped")
	t.eq(world.phases[1], "RunEnded")
	t.eq(world.phases[#world.phases], "Results")
	t.eq(resolvedWith[1][a], "Dead")
	t.eq(resolvedWith[1][b], "Dead")
	t.eq(a:GetAttribute(P.RunOutcome), "Dead")
	t.eq(credits(a), 2 * GameConfig.CreditsPerLevelCleared, "paid per floor sealed")
	t.eq(credits(b), GameConfig.CreditsPerLevelCleared)
	local summary = summaries(world, a)[1]
	t.truthy(summary, "each participant gets a summary")
	t.eq(summary.outcome, "Dead")
	t.eq(summary.creditsEarned, 2 * GameConfig.CreditsPerLevelCleared)
	t.eq(summary.levelsCleared, 2)
	t.eq(summary.runSeconds, 300)
	t.eq(summary.escapees, 0)
	t.eq(summary.squadSize, 2)
	t.eq(summary.saved, true)
	t.eq(summary.stats.CreditsEarned, 2 * GameConfig.CreditsPerLevelCleared, "RunStats records the pay")
	MatchAndDataService.RequestEvaluation()
	flush(world)
	t.eq(#resolvedWith, 1, "a run resolves once")
	connection:Disconnect()
	finish(world, { a, b })
end

spec["Escape: waits for the squad, pays the bonus and the best time"] = function(t: Expect)
	local world = newWorld()
	local runner = join(world)
	local straggler = join(world)
	local escapedSignal: Player? = nil
	local connection = MatchAndDataService.PlayerEscaped:Connect(function(player: Player)
		escapedSignal = player
	end)
	MatchAndDataService.Deploy({ runner, straggler }, "Standard")
	world.floors[runner] = 5
	world.floors[straggler] = 5
	world.now += 640
	t.truthy(MatchAndDataService.MarkEscaped(runner))
	connection:Disconnect()
	t.eq(escapedSignal, runner)
	t.falsy(MatchAndDataService.MarkEscaped(runner), "once")
	t.eq(runner:GetAttribute(P.RunOutcome), "Escaped")
	flush(world)
	t.eq(#world.phases, 0, "the straggler is still alive on the roof")
	world.now += 20
	world.life[straggler] = "Dead"
	MatchAndDataService.RequestEvaluation()
	flush(world)
	t.eq(world.phases[1], "RunEnded")
	local data = MatchAndDataService.GetData(runner)
	t.eq(credits(runner), 5 * GameConfig.CreditsPerLevelCleared + GameConfig.CreditsEscapeBonus)
	t.eq(data and data.Escapes, 1)
	t.eq(data and data.BestTime.Standard, 640, "their own escape time, not the run's end")
	t.eq(credits(straggler), 5 * GameConfig.CreditsPerLevelCleared, "no bonus for dying")
	local summary = summaries(world, runner)[1]
	t.eq(summary.outcome, "Escaped")
	t.eq(summary.runSeconds, 640)
	t.eq(summary.bestTime, 640)
	t.eq(summary.newBest, true)
	t.eq(summary.escapees, 1)
	local other = summaries(world, straggler)[1]
	t.eq(other.outcome, "Dead")
	t.eq(other.escapees, 1, "the client shows DEAD, not WIPED")
	t.falsy(MatchAndDataService.MarkEscaped(straggler), "no escapes after the run resolved")
	finish(world, { runner, straggler })
end

spec["A downed player with a syringe keeps the run alive"] = function(t: Expect)
	local world = newWorld()
	local solo = join(world)
	MatchAndDataService.Deploy({ solo }, "Standard")
	world.life[solo] = "Downed"
	world.syringe[solo] = 1
	MatchAndDataService.RequestEvaluation()
	flush(world)
	t.eq(#world.phases, 0)
	world.syringe[solo] = 0
	MatchAndDataService.RequestEvaluation()
	flush(world)
	t.eq(world.phases[1], "RunEnded")
	finish(world, { solo })
end

spec["A leaver is settled as they go and stops holding the run"] = function(t: Expect)
	local world = newWorld()
	local leaver = join(world)
	local stayer = join(world)
	MatchAndDataService.Deploy({ leaver, stayer }, "Standard")
	world.floors[leaver] = 3
	world.life[stayer] = "Dead"
	MatchAndDataService.RequestEvaluation()
	flush(world)
	t.eq(#world.phases, 0, "the leaver is still alive")
	local userId = leaver.UserId
	world.gone[leaver] = true
	MatchAndDataService.OnPlayerRemoving(leaver)
	t.eq(MatchAndDataService.GetOutcome(leaver), "Disconnected")
	local ok, record = world.backend.read(PlayerDataStore.KeyPrefix .. tostring(userId))
	t.truthy(ok)
	local saved = (record :: any).data
	t.eq(saved.SurvivalCredits, 3 * GameConfig.CreditsPerLevelCleared, "paid for their floors before the release")
	t.eq((record :: any).lock, nil, "and released")
	flush(world)
	t.eq(world.phases[1], "RunEnded", "with the leaver gone, the squad is wiped")
	t.eq(#summaries(world, leaver), 0, "no summary for someone who left")
	t.eq(#summaries(world, stayer), 1)
	finish(world, { stayer })
end

spec["DevRun and guest runs pay nothing"] = function(t: Expect)
	local world = newWorld()
	local dev = join(world)
	MatchAndDataService.Deploy({ dev }, "Standard")
	world.floors[dev] = 4
	world.devRun = true
	MatchAndDataService.MarkEscaped(dev)
	flush(world)
	local summary = summaries(world, dev)[1]
	t.eq(summary.outcome, "Escaped")
	t.eq(summary.creditsEarned, 0)
	t.eq(summary.saved, false)
	t.eq(credits(dev), 0)
	local data = MatchAndDataService.GetData(dev)
	t.eq(data and data.Escapes, 0, "no escape counted for a dev run")
	t.eq(data and data.LastRunId, "")
	finish(world, { dev })

	local guestWorld = newWorld()
	local guest = newPlayer()
	local holder = PlayerDataStore.new({
		backend = guestWorld.backend,
		sessionId = "elsewhere",
		now = function(): number
			return guestWorld.wall
		end,
		wait = function(seconds: number)
			guestWorld.wall += seconds
		end,
	})
	local held = holder:Load(guest.UserId)
	MatchAndDataService.OnPlayerAdded(guest)
	t.falsy(MatchAndDataService.IsWritable(guest))
	MatchAndDataService.Deploy({ guest }, "Standard")
	guestWorld.floors[guest] = 2
	MatchAndDataService.MarkEscaped(guest)
	flush(guestWorld)
	local guestSummary = summaries(guestWorld, guest)[1]
	t.eq(guestSummary.creditsEarned, 0)
	t.eq(guestSummary.saved, false)
	finish(guestWorld, { guest })
	holder:Release(held)
end

--------------------------------------------------------------------------------
-- MatchResetService
--------------------------------------------------------------------------------

type ResetWorld = {
	now: number,
	phase: Enums.MatchPhase,
	gone: { [Player]: boolean },
	endsAt: number?,
	endRuns: number,
	ready: { { Player } },
}

local function resetWorld(): ResetWorld
	local world: ResetWorld = { now = 50, phase = "RunEnded", gone = {}, endsAt = nil, endRuns = 0, ready = {} }
	MatchResetService.SetDependencies({
		now = function(): number
			return world.now
		end,
		phase = function(): Enums.MatchPhase
			return world.phase
		end,
		endRun = function()
			world.endRuns += 1
			world.phase = "Resetting"
			MatchResetService.OnPhaseChanged("Resetting")
			world.phase = "Lobby"
			MatchResetService.OnPhaseChanged("Lobby")
		end,
		present = function(player: Player): boolean
			return not world.gone[player]
		end,
		setEndsAt = function(endsAt: number?)
			world.endsAt = endsAt
		end,
	})
	return world
end

local function enterResults(world: ResetWorld, outcomes: { [Player]: Enums.RunOutcome })
	MatchResetService.OnRunResolved(outcomes)
	world.phase = "Results"
	MatchResetService.OnPhaseChanged("Results")
end

spec["MatchReset: the Results clock and the escape finale"] = function(t: Expect)
	t.eq(MatchResetService.resultsSeconds(0), GameConfig.ResultsSeconds)
	t.eq(MatchResetService.resultsSeconds(2), GameConfig.ResultsSeconds + MatchResetService.EscapeFinaleSeconds)
	local world = resetWorld()
	local connection = MatchResetService.PlayAgainRequested:Connect(function(players: { Player })
		table.insert(world.ready, players)
	end)
	local a, b = newPlayer(), newPlayer()
	enterResults(world, { [a] = "Dead", [b] = "Dead" })
	t.eq(world.endsAt, 50 + GameConfig.ResultsSeconds, "ResultsEndsAt is published")
	t.near(MatchResetService.GetRemaining() or -1, GameConfig.ResultsSeconds, 1e-6)
	world.now += GameConfig.ResultsSeconds - 0.5
	MatchResetService.Poll()
	t.eq(world.endRuns, 0)
	world.now += 0.5
	MatchResetService.Poll()
	t.eq(world.endRuns, 1, "the auto-return")
	t.eq(world.endsAt, nil, "cleared on the way out")
	t.eq(#world.ready, 1)
	t.eq(#world.ready[1], 0, "nobody pressed")
	MatchResetService.Poll(world.now + 100)
	t.eq(world.endRuns, 1, "once")

	enterResults(world, { [a] = "Escaped", [b] = "Dead" })
	t.eq(world.endsAt, world.now + GameConfig.ResultsSeconds + MatchResetService.EscapeFinaleSeconds)
	connection:Disconnect()
	MatchResetService.SetDependencies(nil)
end

spec["MatchReset: everyone pressing Play Again returns at once, pressers arrive ready"] = function(t: Expect)
	local world = resetWorld()
	local connection = MatchResetService.PlayAgainRequested:Connect(function(players: { Player })
		table.insert(world.ready, players)
	end)
	local a, b, watcher = newPlayer(), newPlayer(), newPlayer()
	t.falsy(MatchResetService.HandlePlayAgain(a), "no Results session yet")
	enterResults(world, { [a] = "Dead", [b] = "Escaped" })
	t.truthy(MatchResetService.HandlePlayAgain(watcher), "a spectator may press too")
	t.truthy(MatchResetService.HandlePlayAgain(b))
	t.falsy(MatchResetService.HandlePlayAgain(b), "once each")
	t.eq(world.endRuns, 0, "a participant has not pressed")
	t.truthy(MatchResetService.HandlePlayAgain(a))
	t.eq(world.endRuns, 1, "everyone pressed: straight back")
	local ready = world.ready[1]
	t.truthy(ready and #ready == 3 and ready[1] == watcher and ready[2] == b and ready[3] == a, "in press order")

	enterResults(world, { [a] = "Dead", [b] = "Dead" })
	MatchResetService.HandlePlayAgain(a)
	world.gone[b] = true
	MatchResetService.OnPlayerRemoving(b)
	t.eq(world.endRuns, 2, "the one who left no longer holds the squad")

	local c, d = newPlayer(), newPlayer()
	enterResults(world, { [c] = "Dead", [d] = "Dead" })
	MatchResetService.HandlePlayAgain(c)
	world.gone[c] = true
	MatchResetService.OnPlayerRemoving(c)
	t.eq(world.endRuns, 2, "the other participant has not pressed")
	world.now += 100
	MatchResetService.Poll()
	t.eq(world.endRuns, 3)
	local last = world.ready[#world.ready]
	t.eq(#last, 0, "a presser who left is not readied")
	connection:Disconnect()
	MatchResetService.SetDependencies(nil)
end

--------------------------------------------------------------------------------
-- TelemetryService
--------------------------------------------------------------------------------

spec["Telemetry: builders"] = function(t: Expect)
	local player = newPlayer()
	local number, name = TelemetryService.levelStep("Level0_Basement")
	t.eq(number, 3)
	t.eq(name, "Floor_Level0_Basement")
	local roof = TelemetryService.levelStep("Level5_Roof")
	t.eq(roof, 8)
	t.eq(TelemetryService.Steps.Escape, 9)
	local death = TelemetryService.deathEvent(player, "Bleedout", "Level2_ScienceHall", "Nightmare")
	t.eq(death.name, "Death")
	t.eq(death.value, 2)
	t.eq(death.fields.CustomField01, "Bleedout")
	t.eq(death.fields.CustomField03, "Nightmare")
	local floor = TelemetryService.floorReachedEvent(player, 4, "Dead", "Standard")
	t.eq(floor.value, 4)
	t.eq(floor.fields.CustomField01, "Dead")
	local earned = TelemetryService.economyEvent(player, "RunReward", 10, 130)
	t.truthy(earned and earned.flow == "Source" and earned.amount == 120 and earned.balance == 130)
	t.eq(earned and earned.transaction, "Gameplay")
	local spent = TelemetryService.economyEvent(player, "PerkPurchase", 130, 50)
	t.truthy(spent and spent.flow == "Sink" and spent.amount == 80 and spent.transaction == "Shop")
	t.eq(spent and spent.sku, "PerkPurchase")
	t.eq(TelemetryService.economyEvent(player, "Settings", 50, 50), nil)
end

spec["Telemetry: the funnel in order, once per step"] = function(t: Expect)
	local events: { TelemetryService.Event } = {}
	local player = newPlayer()
	local guids = 0
	local run: Types.RunContext = {
		runId = "telemetry-run",
		seed = 1,
		difficulty = "Standard",
		participants = { player },
		startedAt = 0,
	}
	local current: Types.RunContext? = nil
	TelemetryService.SetDependencies({
		sink = function(event: TelemetryService.Event)
			table.insert(events, event)
		end,
		guid = function(): string
			guids += 1
			return "funnel-" .. guids
		end,
		run = function(): Types.RunContext?
			return current
		end,
		phase = function(): Enums.MatchPhase
			return "Lobby"
		end,
		level = function(): Enums.LevelId?
			return if current then "Level0_Basement" else nil
		end,
	})
	TelemetryService.EnterLobby(player)
	current = run
	TelemetryService.OnLevelActivated("Level0_Basement") -- InRun activates the first level before RunStarted
	TelemetryService.OnRunStarted(run)
	TelemetryService.OnLevelActivated("Level1_Hallways")
	TelemetryService.OnLevelActivated("Level1_Hallways")
	TelemetryService.OnEscaped(player)
	local steps: { number } = {}
	for _, event in events do
		if event.kind == "Funnel" then
			table.insert(steps, event.step)
			t.eq(event.session, "funnel-1", "one funnel session for the trip")
		end
	end
	t.eq(table.concat(steps :: { any }, ","), "1,2,3,4,9")
	TelemetryService.OnRunResolved({ [player] = "Escaped" })
	local last = events[#events]
	t.truthy(last.kind == "Custom" and last.name == "FloorReached" and last.value == 1)
	TelemetryService.OnCommitted(
		player,
		"PerkPurchase",
		DataMigration.defaults(),
		(function(): Types.PlayerData
			local after = DataMigration.defaults()
			after.SurvivalCredits = 0
			return after
		end)()
	)
	t.eq(events[#events], last, "no economy event without a credit change")
	TelemetryService.EnterLobby(player)
	t.eq((events[#events] :: any).session, "funnel-2", "back in the lobby: a new funnel session")
	TelemetryService.SetDependencies(nil)
end

return spec
