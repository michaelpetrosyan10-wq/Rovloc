--!strict
-- LobbyService: the pre-run lobby (spec §1): ready-up, the difficulty vote, the squad cap and the deploy countdown.
-- The only writer of Player Ready / DifficultyVote, of the ReplicatedStorage lobby attributes CountdownEndsAt,
-- LobbySquad and LobbyDifficulty, and of the ready pads' OccupantUserId. It acts only in the Lobby and Countdown
-- phases; RunLifecycleService owns the phases (this service asks it for Countdown and back to Lobby).
--
-- The squad. Players are queued in the order their data loaded (MatchAndDataService.GetData). The squad is the first
-- GameConfig.MaxSquad queued players; later ones wait for the next run (they cannot ready up), players still loading
-- are in neither and never block anyone. A player who sat out a run over the cap moves to the front of the queue
-- when the lobby opens again. LobbySquad publishes the squad (UserIds, slot order) for the clients.
--
-- Ready. Standing on a ReadyPad on the bus readies a squad member (stepping onto any pad sets Ready, stepping off
-- every pad clears it), and LobbyAction Ready / Unready set it from anywhere. A squad member already on a pad when
-- they join the squad (their data loaded, a slot opened) is readied at once. Players who pressed Play Again on the
-- results screen (MatchResetService.PlayAgainRequested) arrive in the lobby already Ready. Every Ready flag clears
-- when the match leaves the lobby and when the lobby opens again. Refusals are told to the player (Notify, at most
-- once every NOTIFY_COOLDOWN seconds per message): Lobby.DataLoading, Lobby.SquadFull.
--
-- The vote. LobbyAction VoteDifficulty at the difficulty terminal (within TERMINAL_REACH studs of its screen) sets
-- DifficultyVote. The squad's cast votes decide: Nightmare only with strictly more votes than Standard (a tie, or no
-- vote at all, plays Standard); LobbyDifficulty publishes the result. Votes are kept until the player leaves.
--
-- The countdown. Once the squad has at least GameConfig.MinSquad members and every one of them is Ready, the match
-- enters Countdown and CountdownEndsAt = now + GameConfig.CountdownSeconds (server time). It aborts (back to Lobby,
-- CountdownEndsAt cleared) as soon as anyone in the squad unreadies or the squad changes (a member leaving, a
-- loaded player taking a free slot); if the squad that remains is still all Ready a fresh countdown starts at once.
-- At zero: MatchAndDataService.Deploy(squad, the voted difficulty). A refused Deploy returns the match to Lobby.
--
-- Terminals. The difficulty console's prompt (LobbyBuilder.Terminals.Difficulty, InteractionService kind Terminal,
-- usable by lobby players in the lobby phases) opens its screen on that player's client: PrivateCue "Terminal"
-- { terminal = AnchorId }. OpenTerminal and IsAtTerminal serve PerkShopService's console the same way. LobbyAction
-- is this service's remote: EquipPerk / UnequipPerk go to the handlers registered with RegisterAction.
--
-- Pure rules (tests/Specs/Lobby.spec.luau): tally, splitSquad, rotate, sameSquad, countdownVerdict, readyRefusal,
-- onPad, padAt, withinReach. SetDependencies swaps the clock, the timer, the player list, the phase, the data layer,
-- bodies, pads, terminals and the senders, so specs run the whole lobby on a fake clock.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local LobbyBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LobbyBuilder)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local MatchAndDataService = require(ServerScriptService.Services.Match.MatchAndDataService)
local MatchResetService = require(ServerScriptService.Services.Match.MatchResetService)

local log = Log.new("Lobby")

local P = Attributes.Player
local M = Attributes.Match
local W = Attributes.World

export type Pad = { id: string, part: BasePart?, center: Vector3 }

export type CountdownVerdict = "Idle" | "Start" | "Keep" | "Abort"

export type ActionHandler = (player: Player, payload: Types.LobbyActionPayload) -> ()

-- The slice of MatchAndDataService the lobby uses (the contract's GetData / Deploy).
export type MatchData = {
	GetData: (player: Player) -> Types.PlayerData?,
	Deploy: (participants: { Player }, difficulty: Enums.Difficulty) -> boolean,
}

export type Dependencies = {
	now: (() -> number)?,
	schedule: ((seconds: number, callback: () -> ()) -> () -> ())?, -- runs `callback` later; returns a cancel
	players: (() -> { Player })?, -- everyone in the server, in arrival order
	phase: (() -> Enums.MatchPhase)?,
	setPhase: ((phase: Enums.MatchPhase) -> boolean)?,
	data: MatchData?,
	rootOf: ((player: Player) -> Vector3?)?, -- a living character's root position
	pads: (() -> { Pad })?,
	terminalAt: ((terminalId: string) -> Vector3?)?, -- a console's screen
	notify: ((player: Player, key: string) -> ())?,
	cue: ((player: Player, payload: Types.PrivateCuePayload) -> ())?,
	matchRoot: Instance?, -- where CountdownEndsAt / LobbySquad / LobbyDifficulty are written (ReplicatedStorage)
}

local TERMINAL_REACH = LobbyBuilder.TerminalPromptDistance + 6 -- the screen may stay open while the player shuffles
local PAD_BELOW = 1 -- a root this far under the pad's centre still counts (uneven floors)
local PAD_ABOVE = 6.5 -- ... and this far over it (a standing R15 root sits about 3 studs up)
local NOTIFY_COOLDOWN = 3
local PADS_RESOLVE_SECONDS = 2
local ZERO_TOLERANCE = 0.05 -- the timer may land this early on the server clock and still deploy
local DEFAULT_DIFFICULTY: Enums.Difficulty = "Standard"
local NIGHTMARE: Enums.Difficulty = "Nightmare"
local TERMINAL_KIND: Enums.PromptKind = "Terminal"
local TERMINAL_CUE: Enums.CueKind = "Terminal"
local DATA_LOADING = "Lobby.DataLoading"
local SQUAD_FULL = "Lobby.SquadFull"
local NOT_AT_TERMINAL = "Lobby.NotAtTerminal"
local NOT_IN_LOBBY = "NotInLobby"

local LOBBY_PHASES: { [string]: boolean } = { Lobby = true, Countdown = true }

local LobbyService = {}

LobbyService.Name = "LobbyService"
LobbyService.TerminalReach = TERMINAL_REACH
LobbyService.PadAbove = PAD_ABOVE
LobbyService.PadBelow = PAD_BELOW
LobbyService.NotifyCooldown = NOTIFY_COOLDOWN
LobbyService.DifficultyTerminal = LobbyBuilder.Terminals.Difficulty

local serviceTrove = Trove.new()
local deps: Dependencies = {}
local initialized = false

local queue: { Player } = {} -- arrival order
local departed: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local ready: { [Player]: boolean } = {}
local votes: { [Player]: Enums.Difficulty } = {}
local padOf: { [Player]: string } = {}
local occupants: { [string]: number } = {} -- pad id -> UserId written on the pad
local pendingReady: { [Player]: boolean } = {}
local benched: { [Player]: boolean } = {}
local squadBefore: { [Player]: boolean } = {}
local notifiedAt: { [Player]: { [string]: number } } = {}
local actionHandlers: { [string]: ActionHandler } = {}

local inLobby = false
local countdownSquad: { Player }? = nil
local countdownEndsAt: number? = nil
local cancelTimer: (() -> ())? = nil
local deploying = false
local evaluating = false
local dirty = false

local padCache: { Pad } = {}
local padsResolvedAt = -math.huge
local terminalCache: { [string]: BasePart } = {}

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Lobby.spec.luau)
--------------------------------------------------------------------------------

-- The difficulty a set of cast votes picks, with the counts: Nightmare only with strictly more votes.
function LobbyService.tally(cast: { Enums.Difficulty }): (Enums.Difficulty, number, number)
	local standard, nightmare = 0, 0
	for _, vote in cast do
		if vote == NIGHTMARE then
			nightmare += 1
		elseif vote == DEFAULT_DIFFICULTY then
			standard += 1
		end
	end
	return if nightmare > standard then NIGHTMARE else DEFAULT_DIFFICULTY, standard, nightmare
end

-- The next run's squad (the first `cap` loaded players in queue order) and the loaded players waiting beyond it.
-- Players still loading are in neither list.
function LobbyService.splitSquad(order: { Player }, loaded: (Player) -> boolean, cap: number): ({ Player }, { Player })
	local squad: { Player } = {}
	local waiting: { Player } = {}
	for _, player in order do
		if not loaded(player) then
			continue
		end
		if #squad < cap then
			table.insert(squad, player)
		else
			table.insert(waiting, player)
		end
	end
	return squad, waiting
end

-- The queue for a new lobby: players who sat out the last run first (in their queue order), then everyone else.
function LobbyService.rotate(order: { Player }, sat: { [Player]: boolean }): { Player }
	local front: { Player } = {}
	local back: { Player } = {}
	for _, player in order do
		table.insert(if sat[player] then front else back, player)
	end
	for _, player in back do
		table.insert(front, player)
	end
	return front
end

-- Whether two squads hold the same players in the same order.
function LobbyService.sameSquad(a: { Player }, b: { Player }): boolean
	if #a ~= #b then
		return false
	end
	for index, player in a do
		if b[index] ~= player then
			return false
		end
	end
	return true
end

-- What the countdown does: Start (Lobby, a big enough squad, everyone Ready), Keep (Countdown, the same squad,
-- everyone still Ready), Abort (Countdown otherwise), Idle (nothing to do).
function LobbyService.countdownVerdict(
	phase: Enums.MatchPhase,
	counting: boolean,
	readyFlags: { boolean },
	sameSquad: boolean,
	minSquad: number
): CountdownVerdict
	local allReady = #readyFlags >= math.max(1, minSquad)
	for _, flag in readyFlags do
		if not flag then
			allReady = false
		end
	end
	if phase == "Lobby" then
		return if allReady and not counting then "Start" else "Idle"
	elseif phase == "Countdown" then
		return if counting and allReady and sameSquad then "Keep" else "Abort"
	end
	return "Idle"
end

-- Why a player may not ready up (nil = they may): outside the lobby phases, data still loading, squad full.
function LobbyService.readyRefusal(lobbyPhase: boolean, loaded: boolean, inSquad: boolean): string?
	if not lobbyPhase then
		return NOT_IN_LOBBY
	elseif not loaded then
		return DATA_LOADING
	elseif not inSquad then
		return SQUAD_FULL
	end
	return nil
end

-- Whether a character root at `position` stands on a pad centred at `center` with `radius`.
function LobbyService.onPad(position: Vector3, center: Vector3, radius: number): boolean
	local rise = position.Y - center.Y
	if rise < -PAD_BELOW or rise > PAD_ABOVE then
		return false
	end
	local dx, dz = position.X - center.X, position.Z - center.Z
	return dx * dx + dz * dz <= radius * radius
end

-- The pad a root at `position` stands on (the nearest one, should two overlap), or nil.
function LobbyService.padAt(position: Vector3, pads: { Pad }): string?
	local best: string? = nil
	local bestDistance = math.huge
	for _, pad in pads do
		if LobbyService.onPad(position, pad.center, LobbyBuilder.PadRadius) then
			local distance = (Vector3.new(position.X, pad.center.Y, position.Z) - pad.center).Magnitude
			if distance < bestDistance then
				best, bestDistance = pad.id, distance
			end
		end
	end
	return best
end

-- Whether `position` is within `reach` studs of `target` (false when either is unknown).
function LobbyService.withinReach(position: Vector3?, target: Vector3?, reach: number): boolean
	if position == nil or target == nil then
		return false
	end
	return (position - target).Magnitude <= reach
end

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

local function now(): number
	local fake = deps.now
	return if fake then fake() else Workspace:GetServerTimeNow()
end

local function schedule(seconds: number, callback: () -> ()): () -> ()
	local fake = deps.schedule
	if fake then
		return fake(seconds, callback)
	end
	local thread = task.delay(seconds, callback)
	return function()
		if coroutine.status(thread) ~= "dead" and coroutine.running() ~= thread then
			pcall(task.cancel, thread)
		end
	end
end

local function presentPlayers(): { Player }
	local fake = deps.players
	return if fake then fake() else Players:GetPlayers()
end

local function currentPhase(): Enums.MatchPhase
	local fake = deps.phase
	return if fake then fake() else RunLifecycleService.GetPhase()
end

local function setPhase(phase: Enums.MatchPhase): boolean
	local fake = deps.setPhase
	return if fake then fake(phase) else RunLifecycleService.SetPhase(phase)
end

local function data(): MatchData
	return deps.data or MatchAndDataService
end

local function isLoaded(player: Player): boolean
	return data().GetData(player) ~= nil
end

local function rootOf(player: Player): Vector3?
	local fake = deps.rootOf
	if fake then
		return fake(player)
	end
	local root = Instances.characterRoot(player)
	local humanoid = Instances.characterHumanoid(player)
	if not root or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return root.CFrame.Position
end

local function lobbyProps(): Instance?
	local lobby = Instances.lobby()
	return if lobby then lobby:FindFirstChild(Instances.Names.Props) else nil
end

local function realPads(): { Pad }
	local stale = #padCache == 0 and now() - padsResolvedAt >= PADS_RESOLVE_SECONDS
	for _, pad in padCache do
		if pad.part == nil or (pad.part :: BasePart).Parent == nil then
			stale = true
		end
	end
	if not stale then
		return padCache
	end
	padsResolvedAt = now()
	table.clear(padCache)
	local props = lobbyProps()
	if not props then
		return padCache
	end
	for _, child in props:GetChildren() do
		local id = child:GetAttribute(W.AnchorId)
		if
			child:IsA("BasePart")
			and type(id) == "string"
			and child:GetAttribute(W.AnchorKind) == "ReadyPad"
			and child.Name == LobbyBuilder.padName(id)
		then
			table.insert(padCache, { id = id, part = child, center = child.CFrame.Position })
		end
	end
	table.sort(padCache, function(a: Pad, b: Pad): boolean
		return a.id < b.id
	end)
	return padCache
end

local function pads(): { Pad }
	local fake = deps.pads
	return if fake then fake() else realPads()
end

local function terminalAt(terminalId: string): Vector3?
	local fake = deps.terminalAt
	if fake then
		return fake(terminalId)
	end
	local cached = terminalCache[terminalId]
	if cached and cached.Parent then
		return cached.CFrame.Position
	end
	local props = lobbyProps()
	local model = if props then props:FindFirstChild(LobbyBuilder.terminalName(terminalId)) else nil
	local screen = if model then model:FindFirstChild("Screen") else nil
	if screen and screen:IsA("BasePart") then
		terminalCache[terminalId] = screen
		return screen.CFrame.Position
	end
	return nil
end

local function matchRoot(): Instance
	return deps.matchRoot or ReplicatedStorage
end

local function notify(player: Player, key: string)
	local now_ = now()
	local perPlayer = notifiedAt[player]
	if not perPlayer then
		perPlayer = {}
		notifiedAt[player] = perPlayer
	end
	local last = perPlayer[key]
	if last and now_ - last < NOTIFY_COOLDOWN then
		return
	end
	perPlayer[key] = now_
	local fake = deps.notify
	if fake then
		fake(player, key)
	else
		Net.Server.fire("Notify", player, { key = key, args = {} } :: Types.NotifyPayload)
	end
end

local function cue(player: Player, payload: Types.PrivateCuePayload)
	local fake = deps.cue
	if fake then
		fake(player, payload)
	else
		Net.Server.fire("PrivateCue", player, payload)
	end
end

-- Swaps in fakes (nil restores every real dependency).
function LobbyService.SetDependencies(fake: Dependencies?)
	deps = fake or {}
	padCache = {}
	padsResolvedAt = -math.huge
	table.clear(terminalCache)
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function isPresent(player: Player): boolean
	return not departed[player] and table.find(presentPlayers(), player) ~= nil
end

-- Brings the queue in line with the server: players join its back once their data has loaded (so a slow load
-- never bumps anyone already in the squad), leavers drop out.
local function syncQueue()
	local present = presentPlayers()
	local seen: { [Player]: boolean } = {}
	for _, player in present do
		seen[player] = true
	end
	for index = #queue, 1, -1 do
		local player = queue[index]
		if departed[player] or not seen[player] then
			table.remove(queue, index)
		end
	end
	for _, player in present do
		if not departed[player] and table.find(queue, player) == nil and isLoaded(player) then
			table.insert(queue, player)
			Attributes.set(player, P.Ready, ready[player] == true)
		end
	end
end

local function squadAndWaiting(): ({ Player }, { Player })
	return LobbyService.splitSquad(queue, isLoaded, GameConfig.MaxSquad)
end

local function inSquad(player: Player): boolean
	local squad = squadAndWaiting()
	return table.find(squad, player) ~= nil
end

local function writeReady(player: Player, value: boolean)
	if value then
		ready[player] = true
	else
		ready[player] = nil
	end
	Attributes.set(player, P.Ready, value)
end

local function votedDifficulty(squad: { Player }): Enums.Difficulty
	local cast: { Enums.Difficulty } = {}
	for _, player in squad do
		local vote = votes[player]
		if vote then
			table.insert(cast, vote)
		end
	end
	return (LobbyService.tally(cast))
end

local function publish(squad: { Player }?)
	local root = matchRoot()
	if not squad then
		Attributes.set(root, M.LobbySquad, nil)
		Attributes.set(root, M.LobbyDifficulty, nil)
		return
	end
	local ids: { string } = {}
	for _, player in squad do
		table.insert(ids, tostring(player.UserId))
	end
	Attributes.set(root, M.LobbySquad, Attributes.joinList(ids))
	Attributes.set(root, M.LobbyDifficulty, votedDifficulty(squad))
end

local function writeOccupant(padId: string, userId: number?)
	if occupants[padId] == userId then
		return
	end
	if userId then
		occupants[padId] = userId
	else
		occupants[padId] = nil
	end
	for _, pad in pads() do
		if pad.id == padId and pad.part then
			Attributes.set(pad.part :: BasePart, W.OccupantUserId, userId)
		end
	end
end

local function clearOccupants()
	for padId in table.clone(occupants) do
		writeOccupant(padId, nil)
	end
	table.clear(padOf)
end

local function clearCountdown()
	local cancel = cancelTimer
	cancelTimer = nil
	if cancel then
		cancel()
	end
	countdownSquad = nil
	countdownEndsAt = nil
	Attributes.set(matchRoot(), M.CountdownEndsAt, nil)
end

--------------------------------------------------------------------------------
-- Countdown
--------------------------------------------------------------------------------

local evaluate: () -> ()

local function waitingNow(): { Player }
	local _, waiting = squadAndWaiting()
	return waiting
end

local function deploy()
	local squad = countdownSquad
	if not squad or deploying then
		return
	end
	local participants = table.clone(squad)
	local difficulty: Enums.Difficulty = votedDifficulty(participants)
	local waiting = waitingNow()
	deploying = true
	clearCountdown()
	log.info("deploying %d player(s) on %s", #participants, difficulty)
	local layer = data()
	local ok, result = pcall(function(): boolean
		return layer.Deploy(participants, difficulty)
	end)
	deploying = false
	if ok and result == true then
		table.clear(benched)
		for _, player in waiting do
			benched[player] = true
		end
	else
		log.warn("Deploy refused (%s)", if ok then "a run is already in progress" else tostring(result))
		if currentPhase() == "Countdown" then
			setPhase("Lobby")
		end
	end
	evaluate()
end

local function onTimer()
	cancelTimer = nil
	local endsAt = countdownEndsAt
	if endsAt == nil or deploying then
		return
	end
	local remaining = endsAt - now()
	if remaining > ZERO_TOLERANCE then
		cancelTimer = schedule(remaining, onTimer)
		return
	end
	evaluate() -- the squad must still be all Ready at zero
	if countdownEndsAt ~= nil and currentPhase() == "Countdown" then
		deploy()
	end
end

local function startCountdown(squad: { Player })
	countdownSquad = table.clone(squad)
	local endsAt = now() + GameConfig.CountdownSeconds
	countdownEndsAt = endsAt
	Attributes.set(matchRoot(), M.CountdownEndsAt, endsAt)
	cancelTimer = schedule(GameConfig.CountdownSeconds, onTimer)
	if not setPhase("Countdown") then
		clearCountdown()
		return
	end
	log.info("countdown: %d player(s), %ds", #squad, GameConfig.CountdownSeconds)
end

local function abortCountdown()
	clearCountdown()
	if currentPhase() == "Countdown" then
		setPhase("Lobby")
	end
	log.info("countdown aborted")
end

local function evaluateOnce()
	syncQueue()
	local phase: Enums.MatchPhase = currentPhase()
	if not LOBBY_PHASES[phase] then
		return
	end
	local squad = squadAndWaiting()
	local members: { [Player]: boolean } = {}
	for _, player in squad do
		members[player] = true
	end
	-- Only squad members are ever Ready.
	for player in table.clone(ready) do
		if not members[player] then
			writeReady(player, false)
		end
	end
	-- A member who joins the squad standing on a pad is ready at once.
	for _, player in squad do
		if not squadBefore[player] and padOf[player] ~= nil then
			writeReady(player, true)
		end
	end
	squadBefore = members
	publish(squad)
	if deploying then
		return
	end
	local flags: { boolean } = {}
	for _, player in squad do
		table.insert(flags, ready[player] == true)
	end
	local counting = countdownEndsAt ~= nil
	local same = counting and LobbyService.sameSquad(countdownSquad or {}, squad)
	local verdict = LobbyService.countdownVerdict(phase, counting, flags, same, GameConfig.MinSquad)
	if verdict == "Start" then
		startCountdown(squad)
	elseif verdict == "Abort" then
		abortCountdown()
	end
end

-- Re-evaluates the lobby; a call made while an evaluation runs (a phase change it caused) runs right after it.
evaluate = function()
	if evaluating then
		dirty = true
		return
	end
	evaluating = true
	local passes = 0
	repeat
		dirty = false
		passes += 1
		xpcall(evaluateOnce, function(err: any)
			log.error("lobby evaluation failed: %s\n%s", tostring(err), debug.traceback())
		end)
	until not dirty or passes >= 4
	evaluating = false
end

--------------------------------------------------------------------------------
-- Lobby open / close
--------------------------------------------------------------------------------

local function openLobby()
	syncQueue()
	clearOccupants()
	for _, player in queue do
		writeReady(player, false)
	end
	for player in pendingReady do
		if isPresent(player) then
			writeReady(player, true)
		end
	end
	table.clear(pendingReady)
	queue = LobbyService.rotate(queue, benched)
	table.clear(benched)
	table.clear(squadBefore)
end

local function closeLobby()
	clearCountdown()
	clearOccupants()
	for player in table.clone(ready) do
		writeReady(player, false)
	end
	table.clear(squadBefore)
	publish(nil)
end

-- RunLifecycleService.PhaseChanged (specs call it from their fake phase setter).
function LobbyService.HandlePhase(phase: Enums.MatchPhase)
	local lobbyNow = LOBBY_PHASES[phase] == true
	if lobbyNow and not inLobby then
		inLobby = true
		openLobby()
	elseif not lobbyNow and inLobby then
		inLobby = false
		closeLobby()
	elseif phase == "Lobby" and countdownEndsAt ~= nil and not deploying then
		-- Somebody else moved Countdown back to Lobby.
		clearCountdown()
	end
	evaluate()
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Readies / unreadies `player`. Returns false (and the refusal) when they may not ready up now.
function LobbyService.SetReady(player: Player, value: boolean): (boolean, string?)
	local lobbyPhase = LOBBY_PHASES[currentPhase()] == true
	if not value then
		if not lobbyPhase then
			return false, NOT_IN_LOBBY
		end
		if ready[player] then
			writeReady(player, false)
			evaluate()
		end
		return true, nil
	end
	syncQueue()
	local refusal = LobbyService.readyRefusal(lobbyPhase, isLoaded(player), inSquad(player))
	if refusal then
		if refusal ~= NOT_IN_LOBBY then
			notify(player, refusal)
		end
		return false, refusal
	end
	if not ready[player] then
		writeReady(player, true)
		evaluate()
	end
	return true, nil
end

function LobbyService.IsReady(player: Player): boolean
	return ready[player] == true
end

-- Whether `player`'s body is within reach of the console `terminalId` (LobbyBuilder.Terminals).
function LobbyService.IsAtTerminal(player: Player, terminalId: string): boolean
	return LobbyService.withinReach(rootOf(player), terminalAt(terminalId), TERMINAL_REACH)
end

-- Records `player`'s difficulty vote (at the difficulty terminal, in the lobby phases).
function LobbyService.SetVote(player: Player, difficulty: Enums.Difficulty): (boolean, string?)
	if not LOBBY_PHASES[currentPhase()] then
		return false, NOT_IN_LOBBY
	end
	if not Enums.has(Enums.Difficulty, difficulty) then
		return false, "Unknown"
	end
	if not LobbyService.IsAtTerminal(player, LobbyBuilder.Terminals.Difficulty) then
		notify(player, NOT_AT_TERMINAL)
		return false, NOT_AT_TERMINAL
	end
	votes[player] = difficulty
	Attributes.set(player, P.DifficultyVote, difficulty)
	evaluate()
	return true, nil
end

-- The difficulty the current squad's votes pick.
function LobbyService.GetVotedDifficulty(): Enums.Difficulty
	local squad = squadAndWaiting()
	return votedDifficulty(squad)
end

-- The next run's squad and the loaded players waiting beyond the cap.
function LobbyService.GetSquad(): ({ Player }, { Player })
	syncQueue()
	return squadAndWaiting()
end

-- Server time the countdown deploys at, or nil.
function LobbyService.GetCountdownEndsAt(): number?
	return countdownEndsAt
end

-- Opens console `terminalId`'s screen on `player`'s client.
function LobbyService.OpenTerminal(player: Player, terminalId: string)
	local at = now()
	cue(player, { kind = TERMINAL_CUE, startAt = at, endsAt = nil, args = { terminal = terminalId } })
end

-- Routes LobbyAction `action` (EquipPerk / UnequipPerk) to `handler` (PerkShopService).
function LobbyService.RegisterAction(action: Enums.LobbyActionKind, handler: ActionHandler)
	actionHandlers[action] = handler
end

-- The LobbyAction remote (Net already rate-limited it, checked the phase and validated the payload).
function LobbyService.HandleAction(player: Player, payload: Types.LobbyActionPayload)
	local action = payload.action
	if action == "Ready" then
		LobbyService.SetReady(player, true)
	elseif action == "Unready" then
		LobbyService.SetReady(player, false)
	elseif action == "VoteDifficulty" then
		local difficulty: Enums.Difficulty? = payload.difficulty
		if difficulty ~= nil then
			LobbyService.SetVote(player, difficulty)
		end
	else
		local handler = actionHandlers[action]
		if handler then
			handler(player, payload)
		end
	end
end

-- MatchResetService.PlayAgainRequested: these players arrive in the lobby Ready (at once when it is already open).
function LobbyService.HandlePlayAgain(players: { Player })
	for _, player in players do
		if not isPresent(player) then
			continue
		end
		if inLobby then
			LobbyService.SetReady(player, true)
		else
			pendingReady[player] = true
		end
	end
end

-- MatchAndDataService.DataLoaded (and a joining player): the squad may have changed.
function LobbyService.HandleDataLoaded(_player: Player)
	evaluate()
end

-- One pad pass (GameConfig.ServerTickHz): stepping onto a pad readies, stepping off every pad unreadies.
function LobbyService.Poll()
	if not inLobby then
		return
	end
	syncQueue()
	local padList = pads()
	local claimed: { [string]: number } = {}
	-- Everyone's feet are tracked, so a player standing on a pad when their data loads or a slot opens is readied.
	for _, player in table.clone(presentPlayers()) do
		if departed[player] then
			continue
		end
		local position = rootOf(player)
		local pad = if position then LobbyService.padAt(position, padList) else nil
		local before = padOf[player]
		if pad then
			padOf[player] = pad
			if claimed[pad] == nil then
				claimed[pad] = player.UserId
			end
		else
			padOf[player] = nil
		end
		if pad and not before then
			LobbyService.SetReady(player, true)
		elseif before and not pad and ready[player] then
			LobbyService.SetReady(player, false)
		end
	end
	for _, pad in padList do
		writeOccupant(pad.id, claimed[pad.id])
	end
end

-- The difficulty console's prompt.
LobbyService.TerminalHandler = {
	kind = TERMINAL_KIND,
	filter = function(host: Instance, _prompt: ProximityPrompt): boolean
		return host:GetAttribute(W.AnchorId) == LobbyBuilder.Terminals.Difficulty
	end,
	canUse = function(_player: Player, _prompt: ProximityPrompt, _host: Instance): (boolean, string?)
		if not LOBBY_PHASES[currentPhase()] then
			return false, NOT_IN_LOBBY
		end
		return true, nil
	end,
	onComplete = function(player: Player, _prompt: ProximityPrompt, _host: Instance)
		LobbyService.OpenTerminal(player, LobbyBuilder.Terminals.Difficulty)
	end,
} :: InteractionService.Handler

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onLobbyAction(player: Player, payload: any)
	LobbyService.HandleAction(player, payload :: Types.LobbyActionPayload)
end

function LobbyService.Init()
	if initialized then
		return
	end
	initialized = true
	Net.Server.on("LobbyAction", onLobbyAction)
	serviceTrove:Add(InteractionService.Register(LobbyService.TerminalHandler))
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(LobbyService.HandlePhase))
	serviceTrove:Add(MatchAndDataService.DataLoaded:Connect(LobbyService.HandleDataLoaded))
	serviceTrove:Add(MatchResetService.PlayAgainRequested:Connect(LobbyService.HandlePlayAgain))
	serviceTrove:Connect(Players.PlayerAdded, LobbyService.HandleDataLoaded)
end

function LobbyService.Start()
	LobbyService.HandlePhase(RunLifecycleService.GetPhase())
	local interval = 1 / GameConfig.ServerTickHz
	local accumulated = 0
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		accumulated += dt
		if accumulated < interval then
			return
		end
		accumulated = 0
		xpcall(LobbyService.Poll, function(err: any)
			log.warnThrottled("poll", 10, "lobby pad poll failed: %s", tostring(err))
		end)
	end)
end

function LobbyService.OnPlayerRemoving(player: Player)
	departed[player] = true
	ready[player] = nil
	votes[player] = nil
	pendingReady[player] = nil
	benched[player] = nil
	squadBefore[player] = nil
	notifiedAt[player] = nil
	local pad = padOf[player]
	padOf[player] = nil
	if pad and occupants[pad] == player.UserId then
		writeOccupant(pad, nil)
	end
	evaluate()
end

-- Forgets every player and countdown (specs start each case from a clean lobby).
function LobbyService.Reset()
	clearCountdown()
	clearOccupants()
	table.clear(queue)
	table.clear(ready)
	table.clear(votes)
	table.clear(pendingReady)
	table.clear(benched)
	table.clear(squadBefore)
	table.clear(notifiedAt)
	table.clear(departed)
	inLobby = false
	deploying = false
	evaluating = false
	dirty = false
end

return LobbyService
