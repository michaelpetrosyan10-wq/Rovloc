--!strict
-- MatchResetService: Results -> Resetting -> Lobby, and Play Again (spec §1, "Full Match Reset").
--
--   * MatchAndDataService.RunResolved opens a Results session for the run's participants (and counts the escapes).
--   * Entering Results arms the auto-return: now + GameConfig.ResultsSeconds, plus ESCAPE_FINALE_SECONDS when anyone
--     escaped (their finale shot plays before the ESCAPED screen appears), written to ReplicatedStorage.ResultsEndsAt
--     (server time; EscapeSummaryController's countdown bar). This service is the only writer of ResultsEndsAt.
--   * PlayAgain (Net admits it in Results only) marks the presser. Once every participant still in the server has
--     pressed, or at the deadline, RunLifecycleService.EndRun runs: Resetting (every service's EndRun clears the run's
--     traps, grates, flasks, doors, lockers, the Creature and Workspace.Runtime) -> Lobby (everyone back in the lobby).
--   * Back in the Lobby, PlayAgainRequested(players) fires with everyone who pressed and is still here, in press order
--     (participants and spectators alike), so LobbyService puts them on the bus already Ready. It fires once per Results
--     session, also when the run was ended another way during Results (the dev `endrun`), possibly with an empty list.
--   * A participant leaving during Results no longer holds the others back; if nobody is left, the reset runs at once.
--
-- Pure (tests/Specs/MatchFlow.spec.luau): resultsSeconds, everyonePressed. SetDependencies swaps the clock, the phase,
-- EndRun and presence; Poll(now?) is the deadline check (Heartbeat; specs call it on a fake clock), and the handlers
-- Init wires (OnRunResolved, OnPhaseChanged, HandlePlayAgain) are public so specs drive a whole Results session.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local MatchAndDataService = require(ServerScriptService.Services.Match.MatchAndDataService)

local log = Log.new("MatchReset")

local M = Attributes.Match

export type Dependencies = {
	now: (() -> number)?,
	phase: (() -> Enums.MatchPhase)?,
	endRun: (() -> ())?,
	present: ((player: Player) -> boolean)?,
	setEndsAt: ((endsAt: number?) -> ())?,
}

type Session = {
	participants: { Player },
	escapees: number,
	pressed: { Player },
	gone: { [Player]: boolean },
	deadline: number?,
	finishing: boolean,
}

-- The finale shot after the last landing (ParachuteController's lookback, two lightning flashes, the fade to black)
-- plays before the ESCAPED screen, so an escape gets this much longer on the Results clock.
local ESCAPE_FINALE_SECONDS = 8
local POLL_SECONDS = 0.25

local MatchResetService = {}

MatchResetService.Name = "MatchResetService"
MatchResetService.EscapeFinaleSeconds = ESCAPE_FINALE_SECONDS

local playAgainRequested: Signal.Signal<{ Player }> = Signal.new()

-- (players) back in the Lobby after Results: everyone who pressed Play Again and is still here (LobbyService readies
-- them).
MatchResetService.PlayAgainRequested = playAgainRequested

local deps: Dependencies = {}
local serviceTrove = Trove.new()
local session: Session? = nil
local initialized = false
local pollAccumulated = 0

--------------------------------------------------------------------------------
-- Pure
--------------------------------------------------------------------------------

-- How long Results lasts when `escapees` participants escaped.
function MatchResetService.resultsSeconds(escapees: number): number
	return GameConfig.ResultsSeconds + (if escapees > 0 then ESCAPE_FINALE_SECONDS else 0)
end

-- Whether every participant still here pressed Play Again (true when none is left).
function MatchResetService.everyonePressed(
	participants: { Player },
	pressed: { Player },
	isHere: (player: Player) -> boolean
): boolean
	for _, player in participants do
		if isHere(player) and table.find(pressed, player) == nil then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

local function now(): number
	local fake = deps.now
	return if fake then fake() else Workspace:GetServerTimeNow()
end

local function currentPhase(): Enums.MatchPhase
	local fake = deps.phase
	return if fake then fake() else RunLifecycleService.GetPhase()
end

local function endRun()
	local fake = deps.endRun
	if fake then
		fake()
	else
		RunLifecycleService.EndRun()
	end
end

local function isPresent(player: Player): boolean
	local fake = deps.present
	return if fake then fake(player) else player.Parent == Players
end

local function setEndsAt(endsAt: number?)
	local fake = deps.setEndsAt
	if fake then
		fake(endsAt)
	else
		ReplicatedStorage:SetAttribute(M.ResultsEndsAt, endsAt)
	end
end

-- Swaps in fakes (nil restores the real clock, lifecycle and presence) and drops any Results session in progress.
function MatchResetService.SetDependencies(fake: Dependencies?)
	deps = fake or {}
	session = nil
end

--------------------------------------------------------------------------------
-- Results
--------------------------------------------------------------------------------

local function stillHere(current: Session): (player: Player) -> boolean
	return function(player: Player): boolean
		return not current.gone[player] and isPresent(player)
	end
end

local function finish(current: Session, why: string)
	if current.finishing or session ~= current then
		return
	end
	current.finishing = true
	log.info("results over (%s): resetting", why)
	task.spawn(function()
		xpcall(endRun, function(err: any)
			log.error("EndRun after Results failed: %s", tostring(err))
		end)
	end)
end

local function checkPressed(current: Session)
	if currentPhase() ~= "Results" then
		return
	end
	if MatchResetService.everyonePressed(current.participants, current.pressed, stillHere(current)) then
		finish(current, "everyone pressed Play Again")
	end
end

-- Opens the Results session for a resolved run (MatchAndDataService.RunResolved).
function MatchResetService.OnRunResolved(outcomes: { [Player]: Enums.RunOutcome })
	local participants: { Player } = {}
	local escapees = 0
	for player, outcome in outcomes do
		table.insert(participants, player)
		if outcome == "Escaped" then
			escapees += 1
		end
	end
	session = {
		participants = participants,
		escapees = escapees,
		pressed = {},
		gone = {},
		deadline = nil,
		finishing = false,
	}
end

-- RunLifecycleService.PhaseChanged: arms the deadline in Results, delivers the pressers back in the Lobby.
function MatchResetService.OnPhaseChanged(phase: Enums.MatchPhase)
	local current = session
	if phase == "Results" then
		if not current then
			return
		end
		local deadline = now() + MatchResetService.resultsSeconds(current.escapees)
		current.deadline = deadline
		setEndsAt(deadline)
		checkPressed(current)
	elseif phase == "Resetting" then
		setEndsAt(nil)
	elseif phase == "Lobby" then
		setEndsAt(nil)
		if not current then
			return
		end
		session = nil
		local ready: { Player } = {}
		for _, player in current.pressed do
			if not current.gone[player] and isPresent(player) then
				table.insert(ready, player)
			end
		end
		log.info("back in the lobby: %d player(s) pressed Play Again", #ready)
		playAgainRequested:Fire(ready)
	end
end

-- A Play Again press. False when there is no Results session or the player already pressed.
function MatchResetService.HandlePlayAgain(player: Player): boolean
	local current = session
	if not current or currentPhase() ~= "Results" or table.find(current.pressed, player) ~= nil then
		return false
	end
	table.insert(current.pressed, player)
	checkPressed(current)
	return true
end

-- The auto-return deadline check.
function MatchResetService.Poll(at: number?)
	local current = session
	if not current or current.finishing then
		return
	end
	local deadline = current.deadline
	if deadline and (at or now()) >= deadline and currentPhase() == "Results" then
		finish(current, "time")
	end
end

-- Seconds of Results left (nil outside a Results session).
function MatchResetService.GetRemaining(): number?
	local current = session
	local deadline = if current then current.deadline else nil
	return if deadline then math.max(0, deadline - now()) else nil
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function MatchResetService.Init()
	if initialized then
		return
	end
	initialized = true
	Net.Server.on("PlayAgain", function(player: Player, _payload: any)
		MatchResetService.HandlePlayAgain(player)
	end)
	serviceTrove:Add(MatchAndDataService.RunResolved:Connect(MatchResetService.OnRunResolved))
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(MatchResetService.OnPhaseChanged))
end

function MatchResetService.Start()
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		pollAccumulated += dt
		if pollAccumulated < POLL_SECONDS then
			return
		end
		pollAccumulated = 0
		MatchResetService.Poll()
	end)
end

function MatchResetService.OnPlayerRemoving(player: Player)
	local current = session
	if not current then
		return
	end
	current.gone[player] = true
	local index = table.find(current.pressed, player)
	if index then
		table.remove(current.pressed, index)
	end
	checkPressed(current)
end

return table.freeze(MatchResetService)
