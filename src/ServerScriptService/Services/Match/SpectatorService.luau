--!strict
-- SpectatorService: who watches the run and through whose eyes (spec §6, first-person spectator camera). The only
-- writer of the Player attributes SpectateReason and SpectateTargetUserId.
--
-- Who spectates. From BeginRun to EndRun every player in the server is in exactly one of these:
--   * a participant who is playing (Alive or Downed): SpectateReason "None";
--   * a participant out of play (LifeState Dead, or Spectating: left behind by a stairwell airlock): "Eliminated".
--     CheckpointAirlockService brings them back at the next floor (SetAlive), which ends their spectating;
--   * a player who was present when the run began but was not deployed: "OverCapacity" when the squad was full
--     (GameConfig.MaxSquad participants), else "LateJoin" (their data or ready-up came too late);
--   * a player who joined during the Deploying / InRun phases: "LateJoin". Joiners during RunEnded / Results /
--     Resetting stay in the lobby (the run is over; the next one is theirs).
-- Late joiners and over-capacity players are not participants: they spectate until the run ends and join the next one
-- from the lobby (the airlocks only bring participants back, so they never get a body mid-run). They are made
-- LifeState Spectating (LifeStateService.SetSpectating, so the SpectateCycle remote admits them) and hold no
-- character: one they have is despawned, and one CharacterService gives them later (their first lobby spawn finishing
-- mid-run, a recovery) is despawned the moment it appears. A spawn still in flight is never cancelled here
-- (cancelling a first spawn would leave them body-less after the run too); CharacterService.EndRun puts everyone back
-- in the lobby. Eliminated participants keep their corpse.
--
-- Whom they watch (pickTarget, pure). Targets are the participants who are playing (Alive or Downed), never the
-- spectator. The run's participant order is the ring:
--   * becoming a spectator: the first target after the spectator's own place in the ring (the start for
--     non-participants);
--   * SpectateCycle { direction = ±1 }: the next / previous target from the current one (wrapping; a lone target
--     stays); direction 0 changes nothing;
--   * the target leaving play or the server: the next target after the lost one;
--   * nobody playing: SpectateTargetUserId nil (the run is about to resolve; the client says so).
-- SpectateTargetUserId is the target's UserId (nil without one). Everything is re-evaluated on every life-state
-- change, departure, BeginRun and EndRun; the attributes are only written when they change. EndRun clears them
-- (SpectateReason "None") for everyone.
--
-- Dev command: spectators (read-only: who is spectating, why, and whom).
--
-- Pure rules (tests/Specs/Spectator.spec.luau): reasonFor, candidates, pickTarget. SetDependencies swaps the life
-- state reads, the spectating write, the character reads and despawns, the match phase and the player list, so specs
-- run joins, eliminations, cycling and the run's end without the engine.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local LifeStateService = require(ServerScriptService.Services.Player.LifeStateService)

local log = Log.new("Spectator")

local P = Attributes.Player

-- One player as reasonFor sees them.
export type Standing = {
	inRun: boolean, -- a run exists (BeginRun .. EndRun)
	participant: boolean,
	lifeState: Enums.LifeState,
	admitted: Enums.SpectateReason?, -- the non-participant reason given when they were admitted to watch
}

-- Everything the service reads from the rest of the game (SetDependencies swaps the whole set).
export type Dependencies = {
	lifeState: (player: Player) -> Enums.LifeState,
	setSpectating: (player: Player) -> (),
	character: (player: Player) -> Model?,
	despawn: (player: Player) -> (),
	phase: () -> Enums.MatchPhase,
	players: () -> { Player },
}

local NONE: Enums.SpectateReason = "None"
local JOIN_PHASES: { [string]: boolean } = { Deploying = true, InRun = true }

local SpectatorService = {}

SpectatorService.Name = "SpectatorService"

local changed: Signal.Signal<Player, Enums.SpectateReason, Player?> = Signal.new()

-- (spectator, reason, target) whenever a player's SpectateReason or SpectateTargetUserId changed.
SpectatorService.Changed = changed

local function realDependencies(): Dependencies
	return {
		lifeState = LifeStateService.GetState,
		setSpectating = LifeStateService.SetSpectating,
		character = CharacterService.GetCharacter,
		despawn = CharacterService.Despawn,
		phase = RunLifecycleService.GetPhase,
		players = function(): { Player }
			return Players:GetPlayers()
		end,
	}
end

type Record = { reason: Enums.SpectateReason, target: Player? }

local deps: Dependencies = realDependencies()
local serviceTrove = Trove.new()
local initialized = false

local inRun = false
local order: { Player } = {} -- the run's participants, in run order (the target ring; leavers stay in it)
local gone: { [Player]: boolean } = {} -- players who left the server (still listed while PlayerRemoving runs)
local admitted: { [Player]: Enums.SpectateReason } = {} -- non-participants watching this run
local records: { [Player]: Record } = {}

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Spectator.spec.luau)
--------------------------------------------------------------------------------

local function isPlaying(state: string): boolean
	return state == "Alive" or state == "Downed"
end

-- Why a player spectates right now ("None": they do not).
function SpectatorService.reasonFor(standing: Standing): Enums.SpectateReason
	if not standing.inRun then
		return NONE
	end
	if standing.participant then
		local state = standing.lifeState
		return if state == "Dead" or state == "Spectating" then "Eliminated" else NONE
	end
	return standing.admitted or NONE
end

-- The reason a present non-participant gets when a run of `participantCount` begins without them.
function SpectatorService.admissionReason(participantCount: number): Enums.SpectateReason
	return if participantCount >= GameConfig.MaxSquad then "OverCapacity" else "LateJoin"
end

-- The UserIds a spectator may watch: the participants (in `ring` order) whose life state is playing, minus the
-- spectator.
function SpectatorService.candidates(
	ring: { number },
	lifeStates: { [number]: Enums.LifeState },
	spectator: number
): { [number]: boolean }
	local out: { [number]: boolean } = {}
	for _, userId in ring do
		local state = lifeStates[userId]
		if userId ~= spectator and state ~= nil and isPlaying(state) then
			out[userId] = true
		end
	end
	return out
end

-- The target after a move of `direction` (-1, 0 or 1) around `ring` (UserIds in run order) among `valid`:
--   direction 0 keeps a still-valid `current`, else takes the next valid one after `current`'s place, else after
--   `anchor`'s (the spectator's own place), else from the start of the ring;
--   ±1 steps from `current` (or the anchor, or the ring's edge) to the next valid one that way, wrapping; a lone
--   valid target is returned again. nil when nothing is valid.
function SpectatorService.pickTarget(
	ring: { number },
	valid: { [number]: boolean },
	current: number?,
	anchor: number?,
	direction: number
): number?
	local count = #ring
	if count == 0 then
		return nil
	end
	if direction == 0 and current ~= nil and valid[current] then
		return current
	end
	local step = if direction < 0 then -1 else 1
	local start = (if current ~= nil then table.find(ring, current) else nil)
		or (if anchor ~= nil then table.find(ring, anchor) else nil)
		or (if step > 0 then 0 else count + 1)
	for offset = 1, count do
		local index = ((start - 1 + step * offset) % count) + 1
		local userId = ring[index]
		if valid[userId] then
			return userId
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Records
--------------------------------------------------------------------------------

local function ringIds(): { number }
	local ids: { number } = {}
	for _, player in order do
		table.insert(ids, player.UserId)
	end
	return ids
end

local function playerById(userId: number?): Player?
	if userId == nil then
		return nil
	end
	for _, player in order do
		if player.UserId == userId then
			return player
		end
	end
	return nil
end

local function standingOf(player: Player): Standing
	return {
		inRun = inRun,
		participant = table.find(order, player) ~= nil,
		lifeState = deps.lifeState(player),
		admitted = admitted[player],
	}
end

-- Plain string comparisons: comparing two SpectateReason unions directly would widen both to string.
local function spectates(reason: string): boolean
	return reason ~= "None"
end

local function sameReason(a: string, b: string): boolean
	return a == b
end

local function write(player: Player, reason: Enums.SpectateReason, target: Player?)
	local record = records[player]
	local previousReason: Enums.SpectateReason = if record then record.reason else NONE
	local previousTarget: Player? = if record then record.target else nil
	if spectates(reason) then
		records[player] = { reason = reason, target = target }
	else
		records[player] = nil
	end
	Attributes.set(player, P.SpectateReason, reason)
	Attributes.set(player, P.SpectateTargetUserId, if target then target.UserId else nil)
	local moved = not sameReason(previousReason, reason) or previousTarget ~= target
	if moved then
		changed:Fire(player, reason, target)
	end
end

-- The spectator's target after a move of `direction` from their current one.
local function targetFor(player: Player, direction: number): Player?
	local ring = ringIds()
	local states: { [number]: Enums.LifeState } = {}
	for _, participant in order do
		if not gone[participant] then
			states[participant.UserId] = deps.lifeState(participant)
		end
	end
	local valid = SpectatorService.candidates(ring, states, player.UserId)
	local record = records[player]
	local current = if record and record.target then record.target.UserId else nil
	return playerById(SpectatorService.pickTarget(ring, valid, current, player.UserId, direction))
end

-- A non-participant spectator holds no body during the run.
local function strip(player: Player)
	if deps.character(player) ~= nil then
		deps.despawn(player)
	end
end

-- Lets a present non-participant watch the run.
local function admit(player: Player, reason: Enums.SpectateReason)
	if admitted[player] ~= nil or table.find(order, player) ~= nil then
		return
	end
	admitted[player] = reason
	deps.setSpectating(player)
	strip(player)
	log.info("%s spectates this run (%s)", player.Name, reason)
end

-- Re-evaluates every player's reason and target (cheap: a squad is at most a handful of players).
function SpectatorService.Refresh()
	for _, player in deps.players() do
		if gone[player] then
			continue
		end
		local reason: Enums.SpectateReason = SpectatorService.reasonFor(standingOf(player))
		local target = if spectates(reason) then targetFor(player, 0) else nil
		write(player, reason, target)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function SpectatorService.GetReason(player: Player): Enums.SpectateReason
	local record = records[player]
	return if record then record.reason else NONE
end

function SpectatorService.GetTarget(player: Player): Player?
	local record = records[player]
	return if record then record.target else nil
end

function SpectatorService.IsSpectating(player: Player): boolean
	return records[player] ~= nil
end

-- Moves `player`'s view to the next (1) or previous (-1) target. False when they are not spectating or the
-- target did not change.
function SpectatorService.Cycle(player: Player, direction: number): boolean
	local record = records[player]
	if not record or (direction ~= 1 and direction ~= -1) then
		return false
	end
	local before = record.target
	local target = targetFor(player, direction)
	write(player, record.reason, target)
	return target ~= before
end

-- A player joined the server: during a live run they watch it (LateJoin).
function SpectatorService.OnPlayerJoined(player: Player)
	gone[player] = nil
	if not inRun or not JOIN_PHASES[deps.phase()] then
		Attributes.set(player, P.SpectateReason, NONE)
		return
	end
	admit(player, "LateJoin")
	SpectatorService.Refresh()
end

-- CharacterService gave `player` a body: a non-participant spectator loses it again (see the header).
function SpectatorService.OnCharacterSpawned(player: Player)
	if inRun and admitted[player] ~= nil then
		strip(player)
	end
end

-- Swaps in fakes (nil restores the real game).
function SpectatorService.SetDependencies(fake: Dependencies?)
	deps = fake or realDependencies()
end

--------------------------------------------------------------------------------
-- Dev command
--------------------------------------------------------------------------------

local function spectatorsCommand(): string?
	local lines: { string } = {}
	for _, player in deps.players() do
		local record = records[player]
		if record then
			local target = record.target
			table.insert(
				lines,
				string.format("%s: %s -> %s", player.Name, record.reason, if target then target.Name else "nobody")
			)
		end
	end
	if #lines == 0 then
		return if inRun then "nobody is spectating" else "no run in progress"
	end
	table.sort(lines)
	return table.concat(lines, " | ")
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function SpectatorService.Init()
	if initialized then
		return
	end
	initialized = true
	Net.Server.on("SpectateCycle", function(player: Player, payload: Types.SpectateCyclePayload)
		SpectatorService.Cycle(player, payload.direction)
	end)
	serviceTrove:Connect(Players.PlayerAdded, SpectatorService.OnPlayerJoined)
	serviceTrove:Add(LifeStateService.StateChanged:Connect(function()
		if inRun then
			SpectatorService.Refresh()
		end
	end))
	serviceTrove:Add(CharacterService.CharacterSpawned:Connect(function(player: Player)
		-- After CharacterService has finished swapping the rig in.
		task.defer(SpectatorService.OnCharacterSpawned, player)
	end))
	DevToolsService.Register("spectators", "spectators: who is spectating, why, and whom", spectatorsCommand, true)
end

function SpectatorService.BeginRun(ctx: Types.RunContext)
	inRun = true
	table.clear(admitted)
	table.clear(gone)
	order = table.clone(ctx.participants)
	local reason: Enums.SpectateReason = SpectatorService.admissionReason(#ctx.participants)
	for _, player in deps.players() do
		if table.find(order, player) == nil then
			admit(player, reason)
		end
	end
	SpectatorService.Refresh()
end

function SpectatorService.EndRun()
	inRun = false
	for _, player in deps.players() do
		write(player, NONE, nil)
	end
	table.clear(records)
	table.clear(admitted)
	table.clear(order)
	table.clear(gone)
end

function SpectatorService.OnPlayerRemoving(player: Player)
	gone[player] = true
	admitted[player] = nil
	records[player] = nil
	-- Whoever watched them moves on to the next target after them in the ring.
	for spectator, record in table.clone(records) do
		if record.target == player then
			write(spectator, record.reason, targetFor(spectator, 0))
		end
	end
end

return SpectatorService
