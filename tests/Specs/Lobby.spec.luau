--!strict
-- Lobby. LobbyService's pure rules (the vote tally, the squad split and rotation, the countdown verdict table, ready
-- refusals, pad and console geometry) and the whole lobby on a fake clock with every dependency injected (players,
-- phases through RunLifecycleService's own transition table, a data layer keeping the MatchAndDataService contract,
-- bodies, pads, consoles, senders): ready pads, refusals, the countdown into Deploy with the voted difficulty,
-- aborts and restarts, a refused Deploy, the squad cap and its rotation, Play Again, the consoles. PerkShopService's
-- purchase mutate, atomic purchases through Update (once per request, never below zero, nothing on any refusal,
-- guests refused), equipping against stock, the lobby's pruning after a deploy spent the units, and the stock mirror.
-- Then LobbyController's pure presentation rules.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LobbyBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LobbyBuilder)
local PerkConfig = require(ReplicatedStorage.Shared.Config.PerkConfig)
local Strings = require(ReplicatedStorage.Shared.Strings)
local Types = require(ReplicatedStorage.Shared.Types)

local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local LobbyService = require(ServerScriptService.Services.Match.LobbyService)
local PerkShopService = require(ServerScriptService.Services.Match.PerkShopService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

local LobbyController = require(StarterPlayer.StarterPlayerScripts.Controllers.Match.LobbyController)

type Expect = SpecRunner.Expect

type Timer = { at: number, callback: () -> (), cancelled: boolean }

type Deployed = { participants: { Player }, difficulty: Enums.Difficulty }

type Note = { player: Player, key: string }

type World = {
	now: number,
	timers: { Timer },
	phase: Enums.MatchPhase,
	phases: { Enums.MatchPhase },
	players: { Player },
	store: { [Player]: Types.PlayerData },
	guests: { [Player]: boolean },
	deploys: { Deployed },
	deployResult: boolean,
	roots: { [Player]: Vector3 },
	pads: { LobbyService.Pad },
	terminals: { [string]: Vector3 },
	notes: { Note },
	cues: { { player: Player, payload: Types.PrivateCuePayload } },
	updates: number,
	root: Instance,
	setPhase: (phase: Enums.MatchPhase) -> boolean,
}

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World
local DIFFICULTY_TERMINAL = LobbyBuilder.Terminals.Difficulty
local PERKS_TERMINAL = LobbyBuilder.Terminals.Perks
local DIFFICULTY_AT = Vector3.new(50, 4, 2)
local PERKS_AT = Vector3.new(2, 4, 60)
local BOILER_ROOM = Vector3.new(20, 3, 34)

--------------------------------------------------------------------------------
-- Fakes
--------------------------------------------------------------------------------

local nextUserId = 8800

local function newPlayer(name: string): Player
	nextUserId += 1
	local player = Instance.new("Player")
	player.Name = name
	local writable = player :: any
	writable.UserId = nextUserId
	return player
end

local function defaults(credits: number): Types.PlayerData
	return {
		v = 1,
		Escapes = 0,
		SurvivalCredits = credits,
		BestTime = {},
		PerkStock = {},
		Settings = {},
		LastRunId = "",
	}
end

local function copy(data: Types.PlayerData): Types.PlayerData
	return {
		v = data.v,
		Escapes = data.Escapes,
		SurvivalCredits = data.SurvivalCredits,
		BestTime = { Standard = data.BestTime.Standard, Nightmare = data.BestTime.Nightmare },
		PerkStock = table.clone(data.PerkStock),
		Settings = table.clone(data.Settings),
		LastRunId = data.LastRunId,
	}
end

local function frozen(data: Types.PlayerData): Types.PlayerData
	local snapshot = copy(data)
	table.freeze(snapshot.BestTime)
	table.freeze(snapshot.PerkStock)
	table.freeze(snapshot.Settings)
	return table.freeze(snapshot)
end

local function newWorld(): World
	local world = {
		now = 1000,
		timers = {},
		phase = "Lobby" :: Enums.MatchPhase,
		phases = {},
		players = {},
		store = {},
		guests = {},
		deploys = {},
		deployResult = true,
		roots = {},
		pads = {},
		terminals = { [DIFFICULTY_TERMINAL] = DIFFICULTY_AT, [PERKS_TERMINAL] = PERKS_AT },
		notes = {},
		cues = {},
		updates = 0,
		root = Instance.new("Folder"),
	} :: any
	world.setPhase = function(phase: Enums.MatchPhase): boolean
		if not RunLifecycleService.canTransition(world.phase, phase) then
			return false
		end
		world.phase = phase
		table.insert(world.phases, phase)
		LobbyService.HandlePhase(phase)
		PerkShopService.HandlePhase(phase)
		return true
	end
	return world :: World
end

-- The contract's GetData / Update / Deploy (Update: a draft copy, committed only when mutate returns true).
local function dataLayer(world: World): (LobbyService.MatchData, PerkShopService.MatchData)
	local function getData(player: Player): Types.PlayerData?
		local data = world.store[player]
		return if data then frozen(data) else nil
	end
	local function update(player: Player, _reason: string, mutate: (data: Types.PlayerData) -> boolean): boolean
		local data = world.store[player]
		if not data or world.guests[player] then
			return false
		end
		local draft = copy(data)
		if mutate(draft) ~= true then
			return false
		end
		world.store[player] = draft
		world.updates += 1
		Attributes.set(player, P.Credits, draft.SurvivalCredits)
		return true
	end
	local function deploy(participants: { Player }, difficulty: Enums.Difficulty): boolean
		table.insert(world.deploys, { participants = table.clone(participants), difficulty = difficulty })
		if not world.deployResult then
			return false
		end
		-- MatchAndDataService: consume one unit per equipped perk, then RunLifecycleService.BeginRun.
		for _, player in participants do
			local data = world.store[player]
			if data then
				for _, perk in PerkConfig.parseLoadout(player:GetAttribute(P.Loadout)) do
					local owned = data.PerkStock[perk] or 0
					if owned > 1 then
						data.PerkStock[perk] = owned - 1
					elseif owned == 1 then
						data.PerkStock[perk] = nil
					end
				end
			end
		end
		world.setPhase("Deploying")
		world.setPhase("InRun")
		return true
	end
	local lobbyData: LobbyService.MatchData = { GetData = getData, Deploy = deploy }
	local shopData: PerkShopService.MatchData = { GetData = getData, Update = update }
	return lobbyData, shopData
end

local function install(world: World)
	LobbyService.Reset()
	PerkShopService.Reset()
	local lobbyData, shopData = dataLayer(world)
	LobbyService.SetDependencies({
		now = function(): number
			return world.now
		end,
		schedule = function(seconds: number, callback: () -> ()): () -> ()
			local timer: Timer = { at = world.now + seconds, callback = callback, cancelled = false }
			table.insert(world.timers, timer)
			return function()
				timer.cancelled = true
			end
		end,
		players = function(): { Player }
			return world.players
		end,
		phase = function(): Enums.MatchPhase
			return world.phase
		end,
		setPhase = world.setPhase,
		data = lobbyData,
		rootOf = function(player: Player): Vector3?
			return world.roots[player]
		end,
		pads = function(): { LobbyService.Pad }
			return world.pads
		end,
		terminalAt = function(terminalId: string): Vector3?
			return world.terminals[terminalId]
		end,
		notify = function(player: Player, key: string)
			table.insert(world.notes, { player = player, key = key })
		end,
		cue = function(player: Player, payload: Types.PrivateCuePayload)
			table.insert(world.cues, { player = player, payload = payload })
		end,
		matchRoot = world.root,
	})
	PerkShopService.SetDependencies({
		data = shopData,
		phase = function(): Enums.MatchPhase
			return world.phase
		end,
		atTerminal = function(player: Player): boolean
			return LobbyService.IsAtTerminal(player, PERKS_TERMINAL)
		end,
		notify = function(player: Player, key: string)
			table.insert(world.notes, { player = player, key = key })
		end,
		open = function(player: Player)
			LobbyService.OpenTerminal(player, PERKS_TERMINAL)
		end,
		players = function(): { Player }
			return world.players
		end,
	})
	LobbyService.HandlePhase(world.phase)
	PerkShopService.HandlePhase(world.phase)
end

local function uninstall(world: World)
	LobbyService.Reset()
	PerkShopService.Reset()
	LobbyService.SetDependencies(nil)
	PerkShopService.SetDependencies(nil)
	world.root:Destroy()
	for _, player in world.players do
		player:Destroy()
	end
	for _, pad in world.pads do
		local part = pad.part
		if part then
			part:Destroy()
		end
	end
end

-- Moves the fake clock on, firing due timers in order.
local function advance(world: World, seconds: number)
	local target = world.now + seconds
	while true do
		local nextTimer: Timer? = nil
		for _, timer in world.timers do
			if not timer.cancelled and timer.at <= target and (nextTimer == nil or timer.at < nextTimer.at) then
				nextTimer = timer
			end
		end
		if not nextTimer then
			break
		end
		nextTimer.cancelled = true
		world.now = math.max(world.now, nextTimer.at)
		nextTimer.callback()
	end
	world.now = target
end

-- A player who joined; `credits` loads their data (nil = still loading).
local function join(world: World, name: string, credits: number?): Player
	local player = newPlayer(name)
	table.insert(world.players, player)
	if credits then
		world.store[player] = defaults(credits)
	end
	LobbyService.HandleDataLoaded(player)
	PerkShopService.HandleDataLoaded(player)
	return player
end

local function load(world: World, player: Player, credits: number)
	world.store[player] = defaults(credits)
	LobbyService.HandleDataLoaded(player)
	PerkShopService.HandleDataLoaded(player)
end

local function leave(world: World, player: Player)
	LobbyService.OnPlayerRemoving(player)
	local index = table.find(world.players, player)
	if index then
		table.remove(world.players, index)
	end
end

local function addPads(world: World, count: number)
	for index = 1, count do
		local id = "Spec_ReadyPad_" .. index
		local part: BasePart = Instance.new("Part")
		part.Name = LobbyBuilder.padName(id)
		local center = Vector3.new(80 + 8 * index, 0.06, 24)
		part.CFrame = CFrame.new(center)
		table.insert(world.pads, { id = id, part = part, center = center })
	end
end

local function padCenter(world: World, index: number): Vector3
	return world.pads[index].center
end

local function standOn(world: World, player: Player, index: number)
	world.roots[player] = padCenter(world, index) + Vector3.new(0.4, 3, -0.3)
end

local function action(player: Player, kind: Enums.LobbyActionKind, extra: { [string]: any }?)
	local payload: { [string]: any } = { action = kind }
	if extra then
		for key, value in extra do
			payload[key] = value
		end
	end
	LobbyService.HandleAction(player, payload :: any)
end

local function notesFor(world: World, player: Player, key: string): number
	local count = 0
	for _, note in world.notes do
		if note.player == player and note.key == key then
			count += 1
		end
	end
	return count
end

local function isReady(player: Player): boolean
	return player:GetAttribute(P.Ready) == true
end

local function squadIds(world: World): string
	local value = world.root:GetAttribute(M.LobbySquad)
	return if type(value) == "string" then value else "<nil>"
end

local function ids(players: { Player }): string
	local out: { string } = {}
	for _, player in players do
		table.insert(out, tostring(player.UserId))
	end
	return table.concat(out, ",")
end

-- Plays a run's end: RunEnded -> Results -> Resetting -> Lobby.
local function backToLobby(world: World)
	for _, phase: Enums.MatchPhase in { "RunEnded", "Results", "Resetting", "Lobby" } :: { Enums.MatchPhase } do
		world.setPhase(phase)
	end
end

local function withWorld(body: (world: World) -> ())
	local world = newWorld()
	install(world)
	local failure: any = nil
	local ok = xpcall(body, function(err: any)
		failure = err
	end, world)
	uninstall(world)
	if not ok then
		error(failure, 0)
	end
end

--------------------------------------------------------------------------------
-- Specs
--------------------------------------------------------------------------------

return {
	["tally: Nightmare needs strictly more votes; a tie or no vote plays Standard"] = function(t: Expect)
		local function pick(cast: { Enums.Difficulty }): Enums.Difficulty
			return (LobbyService.tally(cast))
		end
		t.eq(pick({}), "Standard", "no votes")
		t.eq(pick({ "Nightmare" }), "Nightmare", "a lone vote decides")
		t.eq(pick({ "Nightmare", "Standard" }), "Standard", "a tie plays Standard")
		t.eq(pick({ "Nightmare", "Nightmare", "Standard" }), "Nightmare", "majority")
		t.eq(pick({ "Standard", "Standard", "Nightmare", "Nightmare" }), "Standard", "2-2")
		local winner, standard, nightmare = LobbyService.tally({ "Nightmare", "Standard", "Nightmare" })
		t.eq(winner, "Nightmare")
		t.eq(standard, 1)
		t.eq(nightmare, 2)
	end,

	["splitSquad caps the squad and skips loading players; rotate puts those who sat out first"] = function(t: Expect)
		local a, b, c, d, e = newPlayer("A"), newPlayer("B"), newPlayer("C"), newPlayer("D"), newPlayer("E")
		local loading: { [Player]: boolean } = { [b] = true }
		local function loaded(player: Player): boolean
			return not loading[player]
		end
		local squad, waiting = LobbyService.splitSquad({ a, b, c, d, e }, loaded, 3)
		t.eq(ids(squad), ids({ a, c, d }), "first three loaded")
		t.eq(ids(waiting), ids({ e }), "the rest wait; the loading player is in neither")
		local rotated = LobbyService.rotate({ a, b, c, d, e }, { [d] = true, [e] = true })
		t.eq(ids(rotated), ids({ d, e, a, b, c }), "benched first, both orders kept")
		t.truthy(LobbyService.sameSquad({ a, c }, { a, c }))
		t.falsy(LobbyService.sameSquad({ a, c }, { c, a }), "order matters")
		t.falsy(LobbyService.sameSquad({ a }, { a, c }))
		for _, player in { a, b, c, d, e } do
			player:Destroy()
		end
	end,

	["countdownVerdict: start, keep, abort, idle"] = function(t: Expect)
		local verdict = LobbyService.countdownVerdict
		t.eq(verdict("Lobby", false, { true, true }, false, 1), "Start")
		t.eq(verdict("Lobby", false, { true, false }, false, 1), "Idle", "someone not ready")
		t.eq(verdict("Lobby", false, {}, false, 1), "Idle", "nobody in the squad")
		t.eq(verdict("Lobby", false, { true }, false, 2), "Idle", "under MinSquad")
		t.eq(verdict("Countdown", true, { true, true }, true, 1), "Keep")
		t.eq(verdict("Countdown", true, { true, false }, true, 1), "Abort", "an unready")
		t.eq(verdict("Countdown", true, { true, true }, false, 1), "Abort", "the squad changed")
		t.eq(verdict("Countdown", false, { true }, true, 1), "Abort", "a countdown phase without a countdown")
		t.eq(verdict("InRun", false, { true }, false, 1), "Idle")
	end,

	["readyRefusal, pads and consoles"] = function(t: Expect)
		t.eq(LobbyService.readyRefusal(true, true, true), nil)
		t.eq(LobbyService.readyRefusal(true, false, true), "Lobby.DataLoading")
		t.eq(LobbyService.readyRefusal(true, true, false), "Lobby.SquadFull")
		t.eq(LobbyService.readyRefusal(false, true, true), "NotInLobby")
		t.truthy(Strings.has("Lobby.DataLoading") and Strings.has("Lobby.SquadFull"))
		local center = Vector3.new(10, 0.06, 10)
		local radius = LobbyBuilder.PadRadius
		t.truthy(LobbyService.onPad(center + Vector3.new(0, 3, 0), center, radius), "standing root")
		t.truthy(LobbyService.onPad(center + Vector3.new(radius - 0.05, 3, 0), center, radius), "on the ring")
		t.falsy(LobbyService.onPad(center + Vector3.new(radius + 0.1, 3, 0), center, radius), "beside it")
		t.falsy(LobbyService.onPad(center + Vector3.new(0, LobbyService.PadAbove + 0.5, 0), center, radius), "above")
		t.falsy(LobbyService.onPad(center - Vector3.new(0, LobbyService.PadBelow + 0.5, 0), center, radius), "below")
		local pads: { LobbyService.Pad } = {
			{ id = "A", center = Vector3.new(0, 0, 0) },
			{ id = "B", center = Vector3.new(3, 0, 0) },
		}
		t.eq(LobbyService.padAt(Vector3.new(1.2, 3, 0), pads), "A", "the nearer of two overlapping pads")
		t.eq(LobbyService.padAt(Vector3.new(1.8, 3, 0), pads), "B")
		t.eq(LobbyService.padAt(Vector3.new(9, 3, 0), pads), nil)
		t.truthy(
			LobbyService.withinReach(
				Vector3.new(0, 0, LobbyService.TerminalReach),
				Vector3.zero,
				LobbyService.TerminalReach
			)
		)
		t.falsy(LobbyService.withinReach(Vector3.new(0, 0, 20), Vector3.zero, LobbyService.TerminalReach))
		t.falsy(LobbyService.withinReach(nil, Vector3.zero, 10), "no body")
	end,

	["ready pads: on readies, off unreadies, pads carry their occupant"] = function(t: Expect)
		withWorld(function(world: World)
			addPads(world, 4)
			local a = join(world, "PadA", 0)
			local b = join(world, "PadB", 0)
			t.eq(squadIds(world), ids({ a, b }), "squad published in arrival order")
			t.falsy(isReady(a))
			standOn(world, a, 1)
			world.roots[b] = BOILER_ROOM
			LobbyService.Poll()
			t.truthy(isReady(a), "stepping onto a pad readies")
			t.falsy(isReady(b))
			t.eq((world.pads[1].part :: BasePart):GetAttribute(W.OccupantUserId), a.UserId, "occupant marked")
			-- moving pad to pad keeps it; leaving every pad clears it
			standOn(world, a, 2)
			LobbyService.Poll()
			t.truthy(isReady(a), "pad to pad")
			t.eq((world.pads[1].part :: BasePart):GetAttribute(W.OccupantUserId), nil, "old pad freed")
			t.eq((world.pads[2].part :: BasePart):GetAttribute(W.OccupantUserId), a.UserId)
			world.roots[a] = BOILER_ROOM
			LobbyService.Poll()
			t.falsy(isReady(a), "stepping off unreadies")
			-- LobbyAction from anywhere; standing still keeps it
			action(b, "Ready")
			LobbyService.Poll()
			t.truthy(isReady(b), "LobbyAction Ready away from the pads")
			-- unready on a pad stays unready until stepping on again
			standOn(world, a, 3)
			LobbyService.Poll()
			action(a, "Unready")
			LobbyService.Poll()
			t.falsy(isReady(a), "unready on a pad sticks")
			world.roots[a] = BOILER_ROOM
			LobbyService.Poll()
			standOn(world, a, 3)
			LobbyService.Poll()
			t.truthy(isReady(a), "stepping on again readies")
		end)
	end,

	["ready is refused while loading or over the cap; a member who arrives on a pad is readied"] = function(t: Expect)
		withWorld(function(world: World)
			addPads(world, 4)
			local loading = join(world, "Loading", nil)
			local ok, refusal = LobbyService.SetReady(loading, true)
			t.falsy(ok)
			t.eq(refusal, "Lobby.DataLoading")
			t.eq(notesFor(world, loading, "Lobby.DataLoading"), 1, "told once")
			LobbyService.SetReady(loading, true)
			t.eq(notesFor(world, loading, "Lobby.DataLoading"), 1, "throttled")
			advance(world, LobbyService.NotifyCooldown + 0.1)
			LobbyService.SetReady(loading, true)
			t.eq(notesFor(world, loading, "Lobby.DataLoading"), 2, "told again after the cooldown")
			-- standing on a pad while loading: readied the moment the data arrives
			standOn(world, loading, 1)
			LobbyService.Poll()
			t.falsy(isReady(loading))
			-- (the countdown must not start for a squad of one loading player)
			t.eq(world.phase, "Lobby")
			local others: { Player } = {}
			for index = 1, GameConfig.MaxSquad do
				table.insert(others, join(world, "Squad" .. index, 0))
			end
			t.eq(squadIds(world), ids(others), "the cap is filled by loaded players")
			load(world, loading, 0)
			t.falsy(isReady(loading), "over the cap: not readied")
			local refused = LobbyService.SetReady(loading, true)
			t.falsy(refused)
			t.eq(notesFor(world, loading, "Lobby.SquadFull"), 1)
			-- a slot opens: they join the squad standing on their pad, and are readied
			leave(world, others[1])
			t.truthy(isReady(loading), "promoted onto the squad while on a pad")
			t.truthy(string.find(squadIds(world), tostring(loading.UserId), 1, true) ~= nil)
		end)
	end,

	["countdown: the whole squad ready counts down and deploys it on the voted difficulty"] = function(t: Expect)
		withWorld(function(world: World)
			local a = join(world, "CountA", 0)
			local b = join(world, "CountB", 0)
			-- votes: at the console only
			world.roots[a] = DIFFICULTY_AT + Vector3.new(0, -1, 3)
			world.roots[b] = BOILER_ROOM
			action(a, "VoteDifficulty", { difficulty = "Nightmare" })
			action(b, "VoteDifficulty", { difficulty = "Standard" })
			t.eq(a:GetAttribute(P.DifficultyVote), "Nightmare")
			t.eq(b:GetAttribute(P.DifficultyVote), nil, "away from the console")
			t.eq(notesFor(world, b, "Lobby.NotAtTerminal"), 1)
			t.eq(world.root:GetAttribute(M.LobbyDifficulty), "Nightmare", "one vote to none")
			action(a, "Ready")
			t.eq(world.phase, "Lobby", "not everyone is ready")
			t.eq(world.root:GetAttribute(M.CountdownEndsAt), nil)
			action(b, "Ready")
			t.eq(world.phase, "Countdown")
			t.eq(world.root:GetAttribute(M.CountdownEndsAt), world.now + GameConfig.CountdownSeconds)
			t.eq(LobbyService.GetCountdownEndsAt(), world.now + GameConfig.CountdownSeconds)
			advance(world, GameConfig.CountdownSeconds - 0.1)
			t.eq(#world.deploys, 0, "not before zero")
			advance(world, 0.2)
			t.eq(#world.deploys, 1, "deployed at zero")
			local deployed = world.deploys[1]
			t.eq(ids(deployed.participants), ids({ a, b }), "the squad, in slot order")
			t.eq(deployed.difficulty, "Nightmare")
			t.eq(world.phase, "InRun")
			t.falsy(isReady(a), "Ready clears when the match leaves the lobby")
			t.falsy(isReady(b))
			t.eq(world.root:GetAttribute(M.CountdownEndsAt), nil)
			t.eq(world.root:GetAttribute(M.LobbySquad), nil, "no lobby squad during the run")
			-- intents during the run do nothing
			local ok = LobbyService.SetReady(a, true)
			t.falsy(ok)
			t.falsy(isReady(a))
			-- back in the lobby nobody is ready; votes are kept
			backToLobby(world)
			t.falsy(isReady(a))
			t.eq(a:GetAttribute(P.DifficultyVote), "Nightmare", "votes survive the run")
			t.eq(squadIds(world), ids({ a, b }))
		end)
	end,

	["countdown: unreadying or leaving aborts it; a squad still all ready starts afresh"] = function(t: Expect)
		withWorld(function(world: World)
			local a = join(world, "AbortA", 0)
			local b = join(world, "AbortB", 0)
			local c = join(world, "AbortC", 0)
			for _, player in { a, b, c } do
				action(player, "Ready")
			end
			t.eq(world.phase, "Countdown")
			advance(world, 3)
			action(b, "Unready")
			t.eq(world.phase, "Lobby", "an unready aborts")
			t.eq(world.root:GetAttribute(M.CountdownEndsAt), nil)
			advance(world, GameConfig.CountdownSeconds)
			t.eq(#world.deploys, 0, "the aborted timer never deploys")
			action(b, "Ready")
			t.eq(world.phase, "Countdown")
			local firstEnd = world.root:GetAttribute(M.CountdownEndsAt)
			advance(world, 5)
			leave(world, c)
			-- the leave aborted it (Countdown -> Lobby) and the two left, both ready, started a fresh one
			t.truthy(table.find(world.phases, "Lobby") ~= nil)
			t.eq(world.phase, "Countdown")
			t.eq(world.root:GetAttribute(M.CountdownEndsAt), world.now + GameConfig.CountdownSeconds, "restarted")
			t.truthy(world.root:GetAttribute(M.CountdownEndsAt) ~= firstEnd)
			advance(world, GameConfig.CountdownSeconds - 3)
			t.eq(#world.deploys, 0, "the old deadline passed without a deploy")
			advance(world, 3.1)
			t.eq(#world.deploys, 1)
			t.eq(ids(world.deploys[1].participants), ids({ a, b }))
			t.eq(world.deploys[1].difficulty, "Standard", "nobody voted")
		end)
	end,

	["countdown: a newcomer taking a slot aborts it; a refused Deploy returns to the lobby"] = function(t: Expect)
		withWorld(function(world: World)
			local a = join(world, "SoloA", 0)
			action(a, "Ready")
			t.eq(world.phase, "Countdown", "MinSquad 1")
			local newcomer = join(world, "Newcomer", nil)
			t.eq(world.phase, "Countdown", "a player still loading blocks nobody")
			load(world, newcomer, 0)
			t.eq(world.phase, "Lobby", "a loaded newcomer must ready up first")
			action(newcomer, "Ready")
			t.eq(world.phase, "Countdown")
			world.deployResult = false
			advance(world, GameConfig.CountdownSeconds + 0.1)
			t.eq(#world.deploys, 1)
			t.truthy(table.find(world.phases, "Lobby") ~= nil)
			-- the refusal went back to Lobby; everyone still ready, so the next countdown runs
			t.eq(world.phase, "Countdown")
			world.deployResult = true
			advance(world, GameConfig.CountdownSeconds + 0.1)
			t.eq(#world.deploys, 2)
			t.eq(world.phase, "InRun")
		end)
	end,

	["squad cap: the extra player waits, sits the run out and leads the next lobby"] = function(t: Expect)
		withWorld(function(world: World)
			addPads(world, 4)
			local squad: { Player } = {}
			for index = 1, GameConfig.MaxSquad do
				table.insert(squad, join(world, "Cap" .. index, 0))
			end
			local extra = join(world, "CapExtra", 0)
			t.eq(squadIds(world), ids(squad))
			standOn(world, extra, 1)
			LobbyService.Poll()
			t.falsy(isReady(extra), "the pad does not ready a waiting player")
			t.eq(notesFor(world, extra, "Lobby.SquadFull"), 1)
			local waiting = select(2, LobbyService.GetSquad())
			t.eq(ids(waiting), ids({ extra }))
			world.roots[extra] = BOILER_ROOM
			for _, player in squad do
				action(player, "Ready")
			end
			t.eq(world.phase, "Countdown", "the waiting player does not block the countdown")
			advance(world, GameConfig.CountdownSeconds + 0.1)
			t.eq(ids(world.deploys[1].participants), ids(squad), "only the squad deploys")
			backToLobby(world)
			local expected = { extra, squad[1], squad[2], squad[3] }
			t.eq(squadIds(world), ids(expected), "the player who sat out leads the next squad")
			local nextWaiting = select(2, LobbyService.GetSquad())
			t.eq(ids(nextWaiting), ids({ squad[4] }))
		end)
	end,

	["Play Again: players arrive in the lobby Ready and the countdown starts with them"] = function(t: Expect)
		withWorld(function(world: World)
			local a = join(world, "AgainA", 0)
			local b = join(world, "AgainB", 0)
			action(a, "Ready")
			action(b, "Ready")
			advance(world, GameConfig.CountdownSeconds + 0.1)
			t.eq(world.phase, "InRun")
			world.setPhase("RunEnded")
			world.setPhase("Results")
			LobbyService.HandlePlayAgain({ a })
			t.falsy(isReady(a), "not before the lobby opens")
			world.setPhase("Resetting")
			world.setPhase("Lobby")
			t.truthy(isReady(a), "arrived Ready")
			t.falsy(isReady(b), "did not press Play Again")
			t.eq(world.phase, "Lobby")
			-- both pressing it starts the countdown the moment the lobby opens
			action(b, "Ready")
			advance(world, GameConfig.CountdownSeconds + 0.1)
			t.eq(world.phase, "InRun")
			world.setPhase("RunEnded")
			world.setPhase("Results")
			LobbyService.HandlePlayAgain({ a, b })
			world.setPhase("Resetting")
			world.setPhase("Lobby")
			t.eq(world.phase, "Countdown", "everyone pressed Play Again")
			-- a request already in the lobby readies at once; a departed player is ignored
			action(a, "Unready")
			LobbyService.HandlePlayAgain({ a })
			t.truthy(isReady(a))
			local gone = newPlayer("Gone")
			LobbyService.HandlePlayAgain({ gone })
			t.falsy(isReady(gone))
			gone:Destroy()
		end)
	end,

	["consoles: the prompt opens the screen in the lobby only"] = function(t: Expect)
		withWorld(function(world: World)
			local a = join(world, "ConsoleA", 50)
			local handler = LobbyService.TerminalHandler
			local console = Instance.new("Model")
			console:SetAttribute(W.AnchorId, DIFFICULTY_TERMINAL)
			local other = Instance.new("Model")
			other:SetAttribute(W.AnchorId, PERKS_TERMINAL)
			local prompt = Instance.new("ProximityPrompt")
			local filter = handler.filter :: (Instance, ProximityPrompt) -> boolean
			t.truthy(filter(console, prompt))
			t.falsy(filter(other, prompt), "the perks console is the shop's")
			local canUse = handler.canUse :: (Player, ProximityPrompt, Instance) -> (boolean, string?)
			t.truthy((canUse(a, prompt, console)))
			handler.onComplete(a, prompt, console)
			t.eq(#world.cues, 1)
			t.eq(world.cues[1].player, a)
			t.eq(world.cues[1].payload.kind, "Terminal")
			t.eq(world.cues[1].payload.args.terminal, DIFFICULTY_TERMINAL)
			-- the shop's console needs the player's data
			local shop = PerkShopService.TerminalHandler
			local shopFilter = shop.filter :: (Instance, ProximityPrompt) -> boolean
			local shopCanUse = shop.canUse :: (Player, ProximityPrompt, Instance) -> (boolean, string?)
			t.truthy(shopFilter(other, prompt))
			t.falsy(shopFilter(console, prompt))
			local loading = join(world, "ConsoleLoading", nil)
			local allowed, reason = shopCanUse(loading, prompt, other)
			t.falsy(allowed)
			t.eq(reason, "Lobby.DataLoading")
			t.truthy((shopCanUse(a, prompt, other)))
			shop.onComplete(a, prompt, other)
			t.eq(world.cues[2].payload.args.terminal, PERKS_TERMINAL)
			action(a, "Ready")
			advance(world, GameConfig.CountdownSeconds + 0.1)
			t.falsy((canUse(a, prompt, console)), "closed during a run")
			t.falsy((shopCanUse(a, prompt, other)))
			console:Destroy()
			other:Destroy()
			prompt:Destroy()
		end)
	end,

	["purchase mutate: cost, credits and the stock cap"] = function(t: Expect)
		local draft = defaults(130)
		local ok, reason = PerkShopService.purchase(draft, "AdrenalineSyringe")
		t.truthy(ok)
		t.eq(reason, nil)
		t.eq(draft.SurvivalCredits, 130 - PerkConfig.Perks.AdrenalineSyringe.cost)
		t.eq(draft.PerkStock.AdrenalineSyringe, 1)
		local again, refusal = PerkShopService.purchase(draft, "AdrenalineSyringe")
		t.falsy(again)
		t.eq(refusal, "Lobby.NotEnoughCredits")
		t.eq(draft.SurvivalCredits, 10, "unchanged on refusal")
		t.eq(draft.PerkStock.AdrenalineSyringe, 1)
		local full = defaults(10000)
		full.PerkStock.RustyScrewdriver = PerkConfig.MaxStock
		local capped, capReason = PerkShopService.purchase(full, "RustyScrewdriver")
		t.falsy(capped)
		t.eq(capReason, "Lobby.StockFull")
		t.eq(full.SurvivalCredits, 10000)
		local unknown, unknownReason = PerkShopService.purchase(defaults(500), "Crowbar")
		t.falsy(unknown)
		t.eq(unknownReason, "Unknown")
		t.truthy(Strings.has("Lobby.NotEnoughCredits") and Strings.has("Lobby.StockFull"))
	end,

	["purchases go through one atomic Update: once each, never below zero, nothing on refusal"] = function(t: Expect)
		withWorld(function(world: World)
			local a = join(world, "BuyA", 130)
			local cost = PerkConfig.Perks.AdrenalineSyringe.cost
			-- away from the console
			world.roots[a] = BOILER_ROOM
			local away = PerkShopService.Purchase(a, "AdrenalineSyringe")
			t.falsy(away.ok)
			t.eq(away.reason, "Lobby.NotAtTerminal")
			t.eq(away.credits, 130)
			t.eq(world.updates, 0, "no Update away from the console")
			-- at the console: two requests with credits for one
			world.roots[a] = PERKS_AT + Vector3.new(3, -1, 0)
			local first = PerkShopService.Purchase(a, "AdrenalineSyringe")
			local second = PerkShopService.Purchase(a, "AdrenalineSyringe")
			t.truthy(first.ok)
			t.eq(first.credits, 130 - cost)
			t.eq(first.stock, 1)
			t.falsy(second.ok)
			t.eq(second.reason, "Lobby.NotEnoughCredits")
			t.eq(second.credits, 130 - cost, "the refused request spent nothing")
			t.eq(second.stock, 1, "and added nothing")
			t.eq(world.updates, 1, "exactly one commit")
			t.eq(world.store[a].SurvivalCredits, 130 - cost)
			t.eq(a:GetAttribute(P.Credits), 130 - cost, "credits mirrored by the data layer")
			t.eq(a:GetAttribute(P.PerkStock), "AdrenalineSyringe:1", "stock mirrored")
			-- a guest's read-only data refuses the Update: nothing changes
			local guest = join(world, "Guest", 500)
			world.guests[guest] = true
			world.roots[guest] = PERKS_AT
			local refused = PerkShopService.Purchase(guest, "LithiumCell")
			t.falsy(refused.ok)
			t.eq(refused.reason, "Lobby.PurchaseFailed")
			t.eq(refused.credits, 500)
			t.eq(refused.stock, 0)
			-- still loading
			local loading = join(world, "BuyLoading", nil)
			world.roots[loading] = PERKS_AT
			local early = PerkShopService.Purchase(loading, "LithiumCell")
			t.falsy(early.ok)
			t.eq(early.reason, "Lobby.DataLoading")
			-- outside the lobby phases
			action(a, "Ready")
			action(guest, "Ready")
			advance(world, GameConfig.CountdownSeconds + 0.1)
			t.eq(world.phase, "InRun")
			local late = PerkShopService.Purchase(a, "RustyScrewdriver")
			t.falsy(late.ok)
			t.eq(world.updates, 1)
		end)
	end,

	["equip needs a unit; unequip always; the lobby drops perks a deploy spent"] = function(t: Expect)
		withWorld(function(world: World)
			local routed: { string } = {}
			LobbyService.RegisterAction("EquipPerk", function(player: Player, payload: Types.LobbyActionPayload)
				table.insert(routed, "Equip")
				local perk: Enums.PerkId? = payload.perk
				if perk ~= nil then
					PerkShopService.Equip(player, perk)
				end
			end)
			LobbyService.RegisterAction("UnequipPerk", function(player: Player, payload: Types.LobbyActionPayload)
				table.insert(routed, "Unequip")
				local perk: Enums.PerkId? = payload.perk
				if perk ~= nil then
					PerkShopService.Unequip(player, perk)
				end
			end)
			local a = join(world, "EquipA", 200)
			world.roots[a] = PERKS_AT
			local ok, refusal = PerkShopService.Equip(a, "LithiumCell")
			t.falsy(ok)
			t.eq(refusal, "Lobby.NoStock")
			t.eq(notesFor(world, a, "Lobby.NoStock"), 1)
			t.truthy(PerkShopService.Purchase(a, "LithiumCell").ok)
			t.truthy(PerkShopService.Purchase(a, "RustyScrewdriver").ok)
			action(a, "EquipPerk", { perk = "LithiumCell" })
			action(a, "EquipPerk", { perk = "RustyScrewdriver" })
			action(a, "EquipPerk", { perk = "LithiumCell" })
			t.eq(table.concat(routed, ","), "Equip,Equip,Equip", "LobbyAction routes to the shop")
			t.eq(a:GetAttribute(P.Loadout), "RustyScrewdriver,LithiumCell", "canonical order, each once")
			-- away from the console
			world.roots[a] = BOILER_ROOM
			local away = PerkShopService.Unequip(a, "LithiumCell")
			t.falsy(away)
			t.eq(a:GetAttribute(P.Loadout), "RustyScrewdriver,LithiumCell")
			world.roots[a] = PERKS_AT
			action(a, "UnequipPerk", { perk = "RustyScrewdriver" })
			t.eq(a:GetAttribute(P.Loadout), "LithiumCell")
			-- deploy spends the unit; the loadout is left alone during the run
			action(a, "Ready")
			advance(world, GameConfig.CountdownSeconds + 0.1)
			t.eq(world.phase, "InRun")
			t.eq(world.store[a].PerkStock.LithiumCell, nil, "the deploy consumed it")
			t.eq(a:GetAttribute(P.Loadout), "LithiumCell", "untouched during the run")
			local during = PerkShopService.Equip(a, "RustyScrewdriver")
			t.falsy(during, "no equipping during a run")
			-- the lobby opens: the spent perk is dropped, the stock mirrored
			backToLobby(world)
			t.eq(a:GetAttribute(P.Loadout), "", "dropped once spent")
			t.eq(a:GetAttribute(P.PerkStock), "RustyScrewdriver:1")
		end)
	end,

	["PerkConfig stock attribute round trip"] = function(t: Expect)
		t.eq(PerkConfig.encodeStock({}), "")
		t.eq(
			PerkConfig.encodeStock({ AdrenalineSyringe = 2, RustyScrewdriver = 1, LithiumCell = 0, Crowbar = 4 }),
			"RustyScrewdriver:1,AdrenalineSyringe:2",
			"Enums order, known perks above zero"
		)
		t.eq(PerkConfig.encodeStock({ LithiumCell = PerkConfig.MaxStock + 30 }), "LithiumCell:" .. PerkConfig.MaxStock)
		local decoded = PerkConfig.decodeStock("RustyScrewdriver:1,AdrenalineSyringe:2,Crowbar:9,LithiumCell:x")
		t.eq(decoded.RustyScrewdriver, 1)
		t.eq(decoded.AdrenalineSyringe, 2)
		t.eq(decoded.Crowbar, nil, "unknown perks dropped")
		t.eq(decoded.LithiumCell, nil, "malformed counts dropped")
		t.eq(next(PerkConfig.decodeStock(nil)), nil)
		t.eq(next(PerkConfig.decodeStock(42)), nil)
	end,

	["LobbyController: squad parsing, hints, banner and votes"] = function(t: Expect)
		local squad = LobbyController.parseSquad("12,7,x,3.5,40")
		t.eq(#squad, 3)
		t.eq(squad[1], 12)
		t.eq(squad[3], 40)
		t.eq(#LobbyController.parseSquad(nil), 0)
		t.eq(LobbyController.hintState(false, false, false), "Loading")
		t.eq(LobbyController.hintState(true, false, true), "Full")
		t.eq(LobbyController.hintState(true, true, false), "ReadyUp")
		t.eq(LobbyController.hintState(true, true, true), "Ready")
		for _, device in { "KeyboardMouse", "Gamepad", "Touch" } do
			for _, state: LobbyController.HintState in
				{ "Loading", "Full", "ReadyUp", "Ready" } :: { LobbyController.HintState }
			do
				local key = LobbyController.hintKey(state, device)
				t.truthy(Strings.has(key), key .. " exists")
			end
		end
		t.eq(LobbyController.hintKey("ReadyUp", "Gamepad"), "Lobby.Hint.ReadyUp.Gamepad")
		t.eq(LobbyController.hintKey("Ready", "Unknown"), "Lobby.Hint.Ready.KeyboardMouse")
		local waiting, noBar = LobbyController.statusText(nil, 100, 1, 3)
		t.eq(waiting, Strings.get("Lobby.WaitingForSquad", 1, 3))
		t.eq(noBar, nil)
		local counting, fraction = LobbyController.statusText(105.5, 100, 3, 3)
		t.eq(counting, Strings.get("Lobby.Countdown", 6))
		t.near(fraction :: number, 5.5 / GameConfig.CountdownSeconds, 1e-6)
		local zero, empty = LobbyController.statusText(99, 100, 3, 3)
		t.eq(zero, Strings.get("Lobby.Countdown", 0))
		t.eq(empty, 0)
		local standard, nightmare = LobbyController.voteCounts({ "Nightmare", "Standard", "Nightmare", "Bogus" })
		t.eq(standard, 1)
		t.eq(nightmare, 2)
		t.truthy(LobbyController.secondCrossed(3.02, 2.98))
		t.falsy(LobbyController.secondCrossed(2.9, 2.5))
		t.falsy(LobbyController.secondCrossed(nil, 2.5))
		t.falsy(LobbyController.secondCrossed(0.1, 0), "zero is the deploy, not a tick")
		t.truthy(LobbyController.visible("Lobby", "Lobby"))
		t.truthy(LobbyController.visible("Countdown", nil))
		t.falsy(LobbyController.visible("InRun", "Lobby"))
		t.falsy(LobbyController.visible("Lobby", "Spectating"))
		t.truthy(LobbyController.inReach(LobbyController.CloseDistance))
		t.falsy(LobbyController.inReach(LobbyController.CloseDistance + 0.1))
		t.falsy(LobbyController.inReach(nil))
		t.truthy(
			LobbyController.CloseDistance < LobbyService.TerminalReach,
			"the screen closes before the server refuses"
		)
	end,

	["LobbyController: Nightmare lines, shop rows and pad lamps"] = function(t: Expect)
		local lines = LobbyController.nightmareLines()
		t.eq(#lines, 5)
		local nightmare = DifficultyConfig.Nightmare
		t.truthy(string.find(lines[2], tostring(nightmare.trapCount), 1, true) ~= nil, "trap count shown")
		t.truthy(string.find(lines[2], tostring(DifficultyConfig.Standard.trapCount), 1, true) ~= nil)
		for _, line in lines do
			t.falsy(string.find(line, "Lobby.", 1, true), "every line resolves: " .. line)
		end
		local cost = PerkConfig.Perks.LithiumCell.cost
		local broke = LobbyController.shopRow("LithiumCell", cost - 1, 0, false)
		t.falsy(broke.buyEnabled)
		t.falsy(broke.equipEnabled, "nothing to equip")
		t.eq(broke.buyText, Strings.get("Lobby.Buy", cost))
		t.eq(broke.ownedText, Strings.get("Lobby.Owned", 0))
		t.eq(broke.equipText, Strings.get("Lobby.Equip"))
		local owned = LobbyController.shopRow("LithiumCell", cost, 2, true)
		t.truthy(owned.buyEnabled)
		t.truthy(owned.equipEnabled)
		t.truthy(owned.equipped)
		t.eq(owned.equipText, Strings.get("Lobby.Unequip"))
		local capped = LobbyController.shopRow("LithiumCell", 10000, PerkConfig.MaxStock, false)
		t.falsy(capped.buyEnabled, "at the stock cap")
		t.eq(LobbyController.lampColor(false, false), LobbyBuilder.PadLampIdle)
		t.truthy(LobbyController.lampColor(true, true) ~= LobbyController.lampColor(true, false))
		t.truthy(LobbyController.lampColor(true, true) ~= LobbyBuilder.PadLampIdle)
		for _, perk: Enums.PerkId in Enums.PerkId do
			t.truthy(Strings.has("Perk." .. perk) and Strings.has("Perk." .. perk .. ".Desc"), perk .. " strings")
		end
	end,

	["LobbyBuilder: consoles carry a disabled Terminal prompt, pads a lamp band"] = function(t: Expect)
		local Geometry = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.Geometry)
		local Builder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder)
		Geometry.setYieldEvery(0)
		local layout = Builder.getLayout("Lobby")
		assert(layout, "the Lobby layout is registered")
		local lobby = LobbyBuilder.build(layout)
		local props = lobby:FindFirstChild("Props")
		assert(props, "the lobby has Props")
		for _, terminalId in { DIFFICULTY_TERMINAL, PERKS_TERMINAL } do
			local model = props:FindFirstChild(LobbyBuilder.terminalName(terminalId))
			assert(model, terminalId)
			t.truthy(model:HasTag("Interactable"), "tagged Interactable")
			t.eq(model:GetAttribute(W.AnchorId), terminalId)
			local screen = model:FindFirstChild("Screen")
			assert(screen, "console screen")
			local prompt = screen:FindFirstChildOfClass("ProximityPrompt")
			assert(prompt, "prompt on the screen")
			t.eq(prompt.Enabled, false, "built disabled")
			t.eq(prompt:GetAttribute(W.PromptKind), "Terminal")
			t.eq(prompt:GetAttribute(W.BaseHold), 0)
			t.eq(prompt.MaxActivationDistance, LobbyBuilder.TerminalPromptDistance)
		end
		local pads = 0
		for _, child in props:GetChildren() do
			local id = child:GetAttribute(W.AnchorId)
			if child:IsA("BasePart") and type(id) == "string" and child.Name == LobbyBuilder.padName(id) then
				pads += 1
				local lamp = props:FindFirstChild(LobbyBuilder.lampName(id))
				assert(lamp and lamp:IsA("BasePart"), "lamp for " .. id)
				t.eq(lamp.Material, Enum.Material.Neon)
				t.eq(lamp.CanCollide, false)
				t.eq(lamp.CanQuery, false)
			end
		end
		t.eq(pads, 4, "four ready pads")
		lobby:Destroy()
	end,
}
