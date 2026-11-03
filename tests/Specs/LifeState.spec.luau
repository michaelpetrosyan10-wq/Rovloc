--!strict
-- LifeStateService: the life-state transition table (lethal events, damage, revive health, what the Humanoid shows),
-- recovery-handler decisions, dev-command targeting, and the live service on a fake clock: damage → Down → revive →
-- the second lethal hit executes, bleedout expiry, damage while downed, Execute idempotence, the self-revive syringe,
-- drowning, a death that bypassed the service, dev commands, and EndRun back to the lobby.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)
local LoadoutService = require(ServerScriptService.Services.Player.LoadoutService)
local PlayerStateService = require(ServerScriptService.Services.Player.PlayerStateService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

type Timer = { at: number, callback: () -> (), thread: thread, cancelled: boolean }

type FakeClock = {
	clock: LifeStateService.Clock,
	advance: (seconds: number) -> (),
	now: () -> number,
}

local MAX = GameConfig.MaxHealth

-- A clock whose time only moves when the spec advances it; due callbacks run in time order.
local function fakeClock(start: number): FakeClock
	local now = start
	local timers: { Timer } = {}
	local clock: LifeStateService.Clock = {
		now = function(): number
			return now
		end,
		delay = function(seconds: number, callback: () -> ()): thread
			local thread = coroutine.create(function() end)
			table.insert(
				timers,
				{ at = now + math.max(0, seconds), callback = callback, thread = thread, cancelled = false }
			)
			return thread
		end,
		cancel = function(thread: thread)
			for _, timer in timers do
				if timer.thread == thread then
					timer.cancelled = true
				end
			end
		end,
	}
	local function advance(seconds: number)
		local target = now + seconds
		while true do
			local nextIndex: number? = nil
			for index, timer in timers do
				if timer.cancelled or timer.at > target then
					continue
				end
				if nextIndex == nil or timer.at < timers[nextIndex].at then
					nextIndex = index
				end
			end
			if nextIndex == nil then
				break
			end
			local timer = table.remove(timers, nextIndex)
			if timer then
				now = math.max(now, timer.at)
				timer.callback()
			end
		end
		now = target
	end
	return {
		clock = clock,
		advance = advance,
		now = function(): number
			return now
		end,
	}
end

local nextUserId = 7300

local function fakePlayer(name: string?): (Player, Humanoid)
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = name or ("LifeStateSpec" .. nextUserId)
	local writable = player :: any
	writable.UserId = nextUserId
	writable.DisplayName = "Display" .. player.Name
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = MAX
	humanoid.Health = MAX
	humanoid.Parent = model
	player.Character = model
	return player, humanoid
end

local function context(players: { Player }): Types.RunContext
	return { runId = "life-state-spec", seed = 1, difficulty = "Standard", participants = players, startedAt = 1000 }
end

-- Runs `body` with `player` in a live run on a fake clock (run stats counting), and always tears it down.
local function inRun(body: (player: Player, humanoid: Humanoid, clock: FakeClock) -> ())
	local clock = fakeClock(1000)
	LifeStateService.SetClock(clock.clock)
	local player, humanoid = fakePlayer()
	local ctx = context({ player })
	RunStatsService.BeginRun(ctx)
	PlayerStateService.BeginRun(ctx)
	LifeStateService.BeginRun(ctx)
	local failure: string? = nil
	xpcall(body, function(err: any)
		failure = tostring(err)
	end, player, humanoid, clock)
	LifeStateService.EndRun()
	PlayerStateService.EndRun()
	RunStatsService.EndRun()
	LifeStateService.OnPlayerRemoving(player)
	PlayerStateService.OnPlayerRemoving(player)
	LifeStateService.SetClock(nil)
	if failure ~= nil then
		error(failure, 0)
	end
end

return {
	["rules: lethal events down once, then execute"] = function(t: Expect)
		local lethal = LifeStateService.lethalAction
		t.eq(lethal("Alive", 0), "Down")
		t.eq(lethal("Alive", 1), "Execute", "already downed once this run")
		t.eq(lethal("Downed", 1), "Execute")
		local ignored: { Enums.LifeState } = { "Lobby", "Dead", "Spectating" }
		for _, state: Enums.LifeState in ignored do
			t.eq(lethal(state, 0), "Ignore", state)
		end
		t.truthy(LifeStateService.isPlayingState("Alive"))
		t.truthy(LifeStateService.isPlayingState("Downed"))
		t.falsy(LifeStateService.isPlayingState("Dead"))
	end,

	["rules: damage results"] = function(t: Expect)
		local function check(
			state: Enums.LifeState,
			health: number,
			amount: number,
			downs: number,
			eh: number,
			ea: string
		)
			local h, action = LifeStateService.damageResult(state, health, amount, downs)
			t.eq(h, eh, string.format("%s %d - %d health", state, health, amount))
			t.eq(action, ea, string.format("%s %d - %d action", state, health, amount))
		end
		check("Alive", 100, 30, 0, 70, "Hurt")
		check("Alive", 70, 69.5, 0, 0.5, "Hurt")
		check("Alive", 0.5, 0.5, 0, 0, "Down")
		check("Alive", 70, 70, 0, 0, "Down")
		check("Alive", 70, 500, 1, 0, "Execute")
		check("Downed", 1, 0.1, 1, 1, "Execute")
		check("Lobby", 100, 50, 0, 100, "Ignore")
		check("Dead", 0, 50, 1, 0, "Ignore")
		check("Spectating", 0, 50, 1, 0, "Ignore")
		check("Alive", 100, 0, 0, 100, "Ignore")
		check("Alive", 100, -5, 0, 100, "Ignore")
		check("Alive", 100, 0 / 0, 0, 100, "Ignore")
		check("Alive", 100, math.huge, 0, 100, "Ignore")
	end,

	["rules: revive health and what the Humanoid shows"] = function(t: Expect)
		t.eq(LifeStateService.reviveHealth(nil), MAX * 0.5)
		t.eq(LifeStateService.reviveHealth(1), MAX)
		t.eq(LifeStateService.reviveHealth(2), MAX)
		t.eq(LifeStateService.reviveHealth(0), 1, "at least 1")
		t.eq(LifeStateService.reviveHealth(0 / 0), MAX * 0.5)
		t.eq(LifeStateService.humanoidHealth("Alive", 0.4), 1, "never below 1 while alive")
		t.eq(LifeStateService.humanoidHealth("Alive", 64), 64)
		t.eq(LifeStateService.humanoidHealth("Downed", 1), 1)
		t.eq(LifeStateService.humanoidHealth("Dead", 0), 0)
		t.eq(LifeStateService.humanoidHealth("Lobby", 3), MAX)
		t.eq(LifeStateService.humanoidHealth("Spectating", 0), nil, "spectators' rigs are left alone")
	end,

	["rules: recovery handler decisions"] = function(t: Expect)
		local decide = LifeStateService.recoveryDecision
		t.eq(decide("Died", true, true, "Alive"), "Execute", "a bypassing death eliminates")
		t.eq(decide("Died", true, true, "Downed"), "Execute")
		t.eq(decide("Died", true, true, "Dead"), "Keep", "our own Execute: the corpse stays")
		t.eq(decide("Died", true, true, "Spectating"), "Keep")
		t.eq(decide("OutOfBounds", true, true, "Alive"), "Respawn", "fell out: respawn at the level entry")
		t.eq(decide("Lost", true, true, "Downed"), "Respawn", "respawns still Downed")
		t.eq(decide("Lost", true, true, "Dead"), "Keep")
		t.eq(decide("OutOfBounds", true, true, "Spectating"), "Keep")
		t.eq(decide("Died", false, true, "Alive"), "Respawn", "outside a run")
		t.eq(decide("Died", true, false, "Lobby"), "Respawn", "not a participant")
		t.eq(decide("Lost", false, false, "Lobby"), "Respawn")
	end,

	["rules: dev targets match names and display names, unique prefixes only"] = function(t: Expect)
		local alice = fakePlayer("AliceWonder")
		local alina = fakePlayer("AlinaRose")
		local bob = fakePlayer("Bobby")
		local players = { alice, alina, bob }
		t.eq(LifeStateService.findPlayer("alicewonder", players), alice)
		t.eq(LifeStateService.findPlayer("BOB", players), bob, "unique prefix")
		t.eq(LifeStateService.findPlayer("ali", players), nil, "ambiguous prefix")
		t.eq(LifeStateService.findPlayer("alin", players), alina)
		t.eq(LifeStateService.findPlayer("displaybobby", players), bob, "display names count")
		t.eq(LifeStateService.findPlayer("display", players), nil, "a prefix every display name shares")
		t.eq(LifeStateService.findPlayer("zed", players), nil)
		t.eq(LifeStateService.findPlayer("", players), nil)
	end,

	["service: damage, down, revive, then the second lethal hit executes"] = function(t: Expect)
		inRun(function(player: Player, humanoid: Humanoid, clock: FakeClock)
			local events: { string } = {}
			local connections = {
				LifeStateService.StateChanged:Connect(function(who: Player, new: Enums.LifeState, old: Enums.LifeState)
					if who == player then
						table.insert(events, old .. ">" .. new)
					end
				end),
				LifeStateService.Downed:Connect(function(who: Player, cause: string)
					if who == player then
						table.insert(events, "downed:" .. cause)
					end
				end),
				LifeStateService.Revived:Connect(function(who: Player)
					if who == player then
						table.insert(events, "revived")
					end
				end),
				LifeStateService.Executed:Connect(function(who: Player, cause: string)
					if who == player then
						table.insert(events, "executed:" .. cause)
					end
				end),
			}
			t.eq(player:GetAttribute("LifeState"), "Alive")
			t.eq(player:GetAttribute("DownedCount"), 0)
			t.truthy(LifeStateService.IsPlaying(player))

			LifeStateService.Damage(player, 30, "Trap")
			t.eq(LifeStateService.GetHealth(player), 70)
			t.eq(humanoid.Health, 70)
			LifeStateService.Damage(player, 80, "Trap")
			t.eq(LifeStateService.GetState(player), "Downed")
			t.eq(player:GetAttribute("LifeState"), "Downed")
			t.eq(player:GetAttribute("DownedCount"), 1)
			t.eq(humanoid.Health, 1, "a downed player sits at 1")
			t.eq(player:GetAttribute("BleedoutEndsAt"), clock.now() + GameConfig.BleedoutSeconds)
			t.eq(player:GetAttribute("MoveState"), "DownedCrawling", "PlayerStateService holds the crawl")
			t.eq(RunStatsService.Get(player, "TimesDowned"), 1)
			t.truthy(LifeStateService.IsPlaying(player))

			clock.advance(10)
			LifeStateService.Revive(player)
			t.eq(LifeStateService.GetState(player), "Alive")
			t.eq(humanoid.Health, MAX * 0.5)
			t.eq(player:GetAttribute("BleedoutEndsAt"), nil)
			t.eq(player:GetAttribute("MoveState"), "Standing")
			clock.advance(GameConfig.BleedoutSeconds)
			t.eq(LifeStateService.GetState(player), "Alive", "the revive cancelled the bleedout")

			LifeStateService.Damage(player, 1000, "Jumpscare")
			t.eq(LifeStateService.GetState(player), "Dead", "second lethal hit executes")
			t.eq(humanoid.Health, 0)
			t.eq(player:GetAttribute("DownedCount"), 1)
			t.eq(RunStatsService.Get(player, "TimesDowned"), 1, "only Down counts")
			t.falsy(LifeStateService.IsPlaying(player))
			LifeStateService.Execute(player, "Again")
			LifeStateService.Damage(player, 10, "Again")
			LifeStateService.Revive(player)
			t.eq(LifeStateService.GetState(player), "Dead", "Dead ignores everything")
			for _, connection in connections do
				connection:Disconnect()
			end
			t.eq(
				table.concat(events, ","),
				"Alive>Downed,downed:Trap,Downed>Alive,revived,Alive>Dead,executed:Jumpscare",
				"one Executed for repeated calls"
			)
		end)
	end,

	["service: bleedout executes at expiry, damage while downed executes"] = function(t: Expect)
		inRun(function(player: Player, humanoid: Humanoid, clock: FakeClock)
			local causes: { string } = {}
			local connection = LifeStateService.Executed:Connect(function(who: Player, cause: string)
				if who == player then
					table.insert(causes, cause)
				end
			end)
			LifeStateService.Down(player, "Trap")
			t.eq(LifeStateService.GetState(player), "Downed")
			t.eq(LifeStateService.GetBleedoutEndsAt(player), 1000 + GameConfig.BleedoutSeconds)
			clock.advance(GameConfig.BleedoutSeconds - 0.5)
			t.eq(LifeStateService.GetState(player), "Downed")
			clock.advance(1)
			t.eq(LifeStateService.GetState(player), "Dead", "bled out")
			t.eq(causes[1], "Bleedout")
			t.eq(humanoid.Health, 0)
			t.eq(player:GetAttribute("BleedoutEndsAt"), nil)

			-- A dev / checkpoint respawn brings the player back; the second down executes at once.
			LifeStateService.SetAlive(player, 50)
			t.eq(LifeStateService.GetState(player), "Alive")
			t.eq(LifeStateService.GetHealth(player), 50)
			t.eq(humanoid.Health, 0, "a dead Humanoid stays dead until the next character")
			LifeStateService.Down(player, "Trap")
			t.eq(LifeStateService.GetState(player), "Dead", "downed once already")
			t.eq(causes[2], "Trap")

			LifeStateService.SetLobby(player)
			LifeStateService.BeginRun(context({ player }))
			LifeStateService.Down(player, "Trap")
			t.eq(LifeStateService.GetState(player), "Downed", "a new run forgets the downs")
			LifeStateService.Damage(player, 0.1, "Creature")
			t.eq(LifeStateService.GetState(player), "Dead", "any damage while downed executes")
			t.eq(causes[3], "Creature")
			connection:Disconnect()
		end)
	end,

	["service: syringe self-revive, drowning and a bypassing death"] = function(t: Expect)
		LifeStateService.Init()
		inRun(function(player: Player, humanoid: Humanoid)
			LifeStateService.Down(player, "Trap")
			LoadoutService.SyringeUsed:Fire(player, "Stamina")
			t.eq(LifeStateService.GetState(player), "Downed", "the stamina mode does not revive")
			LoadoutService.SyringeUsed:Fire(player, "SelfRevive")
			t.eq(LifeStateService.GetState(player), "Alive")
			t.eq(humanoid.Health, MAX * 0.5)

			PlayerStateService.OxygenDepleted:Fire(player)
			t.eq(LifeStateService.GetState(player), "Dead", "drowning goes through Down (second time: execute)")

			LifeStateService.SetAlive(player)
			humanoid.Health = MAX
			t.truthy(LifeStateService.HandleRecovery(player, player.Character, "Died"), "handled")
			t.eq(LifeStateService.GetState(player), "Dead", "a death that bypassed the service eliminates")
			t.truthy(LifeStateService.HandleRecovery(player, nil, "Lost"), "the dead are never respawned")
			LifeStateService.SetAlive(player)
			t.falsy(LifeStateService.HandleRecovery(player, player.Character, "OutOfBounds"), "built-in respawn")
			t.eq(LifeStateService.GetState(player), "Alive", "the respawn keeps the life state")
		end)
		local lobbyPlayer = fakePlayer()
		t.falsy(LifeStateService.HandleRecovery(lobbyPlayer, nil, "Died"), "outside a run the lobby respawns")
		LifeStateService.OnPlayerRemoving(lobbyPlayer)
	end,

	["service: dev commands"] = function(t: Expect)
		inRun(function(player: Player, humanoid: Humanoid)
			local run = LifeStateService.RunDevCommand
			t.eq(run(player, "hurt", { "25" }), player.Name .. ": Alive 75/" .. MAX)
			t.eq(humanoid.Health, 75)
			t.eq(run(player, "hurt", {}), "usage: hurt <amount> [player]")
			t.eq(run(player, "hurt", { "-3" }), "usage: hurt <amount> [player]")
			t.eq(run(player, "heal", {}), player.Name .. ": Alive 100/" .. MAX)
			t.eq(run(player, "down", {}), player.Name .. ": Downed 1/" .. MAX)
			t.eq(run(player, "heal", {}), player.Name .. ": Alive 100/" .. MAX, "heal revives at full")
			t.eq(run(player, "revive", {}), player.Name .. ": Alive 100/" .. MAX .. " (not down)")
			t.eq(run(player, "kill", {}), player.Name .. ": Dead 0/" .. MAX)
			t.eq(run(player, "heal", {}), player.Name .. ": Dead 0/" .. MAX .. " (cannot heal)")
			t.eq(run(player, "hurt", { "10", "nobody-here" }), 'no single player matches "nobody-here"')
		end)
		local outsider = fakePlayer()
		t.eq(LifeStateService.RunDevCommand(outsider, "kill", {}), "no run in progress")
		LifeStateService.OnPlayerRemoving(outsider)
	end,

	["service: outside a run nothing hurts, EndRun returns everyone to the lobby"] = function(t: Expect)
		local player, humanoid = fakePlayer()
		LifeStateService.SetLobby(player) -- what joining does
		LifeStateService.Damage(player, 50, "Trap")
		LifeStateService.Down(player, "Trap")
		LifeStateService.Execute(player, "Trap")
		t.eq(LifeStateService.GetState(player), "Lobby")
		t.eq(player:GetAttribute("LifeState"), "Lobby")
		t.eq(LifeStateService.GetHealth(player), MAX)
		LifeStateService.OnPlayerRemoving(player)

		inRun(function(runner: Player, runnerHumanoid: Humanoid)
			LifeStateService.Damage(runner, 60, "Trap")
			LifeStateService.Down(runner, "Trap")
			t.eq(LifeStateService.GetState(runner), "Downed")
			LifeStateService.EndRun()
			t.eq(LifeStateService.GetState(runner), "Lobby")
			t.eq(runner:GetAttribute("BleedoutEndsAt"), nil)
			t.eq(runner:GetAttribute("DownedCount"), 0)
			t.eq(runnerHumanoid.Health, MAX)
			t.eq(runner:GetAttribute("MoveState"), "Standing", "the crawl override is gone")
		end)
		t.eq(humanoid.Health, MAX)
	end,
}
