--!strict
-- LifeStateService: health and life state. The only writer of Humanoid.Health and of the Player attributes LifeState,
-- DownedCount and BleedoutEndsAt (docs/ARCHITECTURE.md §5, death rules).
--
-- States: Lobby (not in a run) · Alive · Downed · Dead · Spectating (P8 sets it through SetSpectating).
--   BeginRun      participants → Alive at MaxHealth with DownedCount 0. Everyone else stays Lobby.
--   Damage        Alive: health drops (the Humanoid never shows less than 1 while not dead); lethal damage is a Down.
--                 Downed: any damage executes. Other states ignore damage.
--   Down          the one lethal path (lethal damage, P7 drowning via PlayerStateService.OxygenDepleted, traps,
--                 jumpscares): the first time in a run → Downed (DownedCount + 1, Health 1, BleedoutEndsAt = now +
--                 BleedoutSeconds, a "LifeState" DownedCrawling override on PlayerStateService, a Gasp cue on the
--                 victim, RunStats TimesDowned, bleedout scheduled); already downed once, or Downed now → Execute.
--   Revive        Downed → Alive at healthFraction × MaxHealth (default 0.5); the override and bleedout clear.
--   Execute       Alive / Downed → Dead: LifeState is written first, then Humanoid.Health = 0, so CharacterService's
--                 Died reaches the recovery handler below already Dead and the body stays as a corpse (no respawn)
--                 until EndRun / P8. Idempotent.
--   SetAlive      any state → Alive (P8 checkpoint respawns, dev revives); SetLobby → Lobby at full health;
--                 SetSpectating → Spectating. None of them touch DownedCount except SetLobby (back to 0).
--   EndRun        everyone → Lobby at full health, bleedout cleared.
-- Damage / Down / Execute act only while a run is live (BeginRun .. EndRun, phase Deploying / InRun).
--
-- Characters. Health lives here (GetHealth); every new character of the player gets it applied on
-- CharacterService.CharacterSpawned (a Downed player respawned after falling out of the world is still Downed at 1).
-- Dead and Spectating players' new rigs are left alone so P8 can spawn first and SetAlive after (or the reverse).
--
-- Recovery (CharacterService.SetRecoveryHandler, decided by recoveryDecision): during a live run, for a participant,
--   "Died" while Alive / Downed (a death that bypassed this service: fell, reset) → Execute("Fell"), handled;
--   "Died" / "OutOfBounds" / "Lost" while Dead / Spectating → handled (the corpse stays, nobody respawns);
--   "OutOfBounds" / "Lost" while Alive / Downed → built-in respawn at the level entry (the life state is kept).
-- Outside a live run, or for anyone who is not a participant, the built-in respawn always runs.
--
-- Syringe. LoadoutService.SyringeUsed with mode "SelfRevive" revives at half health (LoadoutService has already
-- checked the life state and spent the charge).
--
-- Dev commands (not read-only): hurt <amount> [player] · down [player] · revive [player] · kill [player] ·
-- heal [player]. They target the caller unless a player is named (name or display name, any case, unique prefix).
--
-- Pure rules (tests/Specs/LifeState.spec.luau): lethalAction, damageResult, reviveHealth, humanoidHealth,
-- recoveryDecision, findPlayer. SetClock swaps the time source so specs can run a bleedout on a fake clock.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Instances = require(ReplicatedStorage.Shared.Instances)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local CharacterService = require(ServerScriptService.Services.Core.CharacterService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local RunStatsService = require(ServerScriptService.Services.Core.RunStatsService)

local LoadoutService = require(script.Parent.LoadoutService)
local PlayerStateService = require(script.Parent.PlayerStateService)

local log = Log.new("LifeState")

local P = Attributes.Player

export type Clock = PlayerStateService.Clock

-- What a lethal event does to a player in a given state.
export type LethalAction = "Down" | "Execute" | "Ignore"

-- What Damage does: Hurt (health dropped, still standing), Down / Execute (lethal), Ignore.
export type DamageAction = "Hurt" | "Down" | "Execute" | "Ignore"

-- The recovery handler's answer: Execute (then handled), Keep (handled, nothing to do), Respawn (built-in respawn).
export type RecoveryDecision = "Execute" | "Keep" | "Respawn"

type Record = {
	state: Enums.LifeState,
	health: number,
	downedCount: number,
	bleedoutEndsAt: number?,
	bleedoutTimer: thread?,
}

local MAX_HEALTH = GameConfig.MaxHealth
local DEFAULT_REVIVE_FRACTION = 0.5
local SYRINGE_REVIVE_FRACTION = 0.5
local DEV_REVIVE_FRACTION = 0.5
local OVERRIDE_TOKEN = PlayerStateService.OverrideToken.LifeState
local DOWNED_STATE: Enums.MoveState = "DownedCrawling"
local GASP_PRESET = "Gasp"
local CAUSE_FELL = "Fell"
local CAUSE_BLEEDOUT = "Bleedout"
local CAUSE_DROWNED = "Drowned"
local CAUSE_DEV = "Dev"
local CAUSE_SYRINGE = "Syringe"

local LifeStateService = {}

LifeStateService.Name = "LifeStateService"
LifeStateService.Causes = table.freeze({
	Fell = CAUSE_FELL,
	Bleedout = CAUSE_BLEEDOUT,
	Drowned = CAUSE_DROWNED,
	Dev = CAUSE_DEV,
	Syringe = CAUSE_SYRINGE,
})

local stateChanged: Signal.Signal<Player, Enums.LifeState, Enums.LifeState> = Signal.new()
local downed: Signal.Signal<Player, string> = Signal.new()
local executed: Signal.Signal<Player, string> = Signal.new()
local revived: Signal.Signal<Player> = Signal.new()
local damaged: Signal.Signal<Player, number, string> = Signal.new()

-- (player, new, old) after every life-state change.
LifeStateService.StateChanged = stateChanged
-- (player, cause) when a player went down.
LifeStateService.Downed = downed
-- (player, cause) when a player was executed (Dead).
LifeStateService.Executed = executed
-- A Downed player is back up.
LifeStateService.Revived = revived
-- (player, amount, cause) for every Damage that landed, after its effect (hurt, downed or executed).
LifeStateService.Damaged = damaged

local realClock: Clock = {
	now = function(): number
		return Workspace:GetServerTimeNow()
	end,
	delay = function(seconds: number, callback: () -> ()): thread
		return task.delay(seconds, callback)
	end,
	cancel = function(thread: thread)
		if coroutine.status(thread) == "suspended" then
			task.cancel(thread)
		end
	end,
}

local clock: Clock = realClock
local serviceTrove = Trove.new()
local records: { [Player]: Record } = {}
local run: Types.RunContext? = nil
local phaseLive = false
local initialized = false

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/LifeState.spec.luau)
--------------------------------------------------------------------------------

function LifeStateService.isPlayingState(state: Enums.LifeState): boolean
	return state == "Alive" or state == "Downed"
end

-- A lethal event (lethal damage, Down) on a player in `state` who has been downed `downedCount` times this run.
function LifeStateService.lethalAction(state: Enums.LifeState, downedCount: number): LethalAction
	if state == "Alive" then
		return if downedCount <= 0 then "Down" else "Execute"
	elseif state == "Downed" then
		return "Execute"
	end
	return "Ignore"
end

-- Damage of `amount` to a player at `health`: the health after it and what happens.
function LifeStateService.damageResult(
	state: Enums.LifeState,
	health: number,
	amount: number,
	downedCount: number
): (number, DamageAction)
	if not MathUtil.isFinite(amount) or amount <= 0 then
		return health, "Ignore"
	end
	if state == "Alive" then
		local remaining = health - amount
		if remaining <= 0 then
			return 0, LifeStateService.lethalAction(state, downedCount)
		end
		return remaining, "Hurt"
	elseif state == "Downed" then
		return health, "Execute"
	end
	return health, "Ignore"
end

-- Health after a revive at `fraction` of MaxHealth (default 0.5), at least 1.
function LifeStateService.reviveHealth(fraction: number?): number
	local share = fraction or DEFAULT_REVIVE_FRACTION
	if not MathUtil.isFinite(share) then
		share = DEFAULT_REVIVE_FRACTION
	end
	return math.clamp(share * MAX_HEALTH, 1, MAX_HEALTH)
end

-- What Humanoid.Health shows for a player in `state` with `health` (nil: leave the Humanoid alone).
function LifeStateService.humanoidHealth(state: Enums.LifeState, health: number): number?
	if state == "Alive" then
		return math.clamp(health, 1, MAX_HEALTH)
	elseif state == "Downed" then
		return 1
	elseif state == "Dead" then
		return 0
	elseif state == "Lobby" then
		return MAX_HEALTH
	end
	return nil
end

-- The recovery handler's decision for `reason` (CharacterService.RecoveryReason).
function LifeStateService.recoveryDecision(
	reason: string,
	runLive: boolean,
	participant: boolean,
	state: Enums.LifeState
): RecoveryDecision
	if not runLive or not participant then
		return "Respawn"
	end
	if state == "Dead" or state == "Spectating" then
		return "Keep"
	end
	if not LifeStateService.isPlayingState(state) then
		return "Respawn"
	end
	if reason == "Died" then
		return "Execute"
	end
	return "Respawn"
end

-- The player `query` names among `players`: an exact name or display name (any case), else the only one whose name
-- or display name starts with it. nil when nobody or more than one player matches.
function LifeStateService.findPlayer(query: string, players: { Player }): Player?
	local lowered = string.lower(query)
	if lowered == "" then
		return nil
	end
	local prefixed: Player? = nil
	local prefixCount = 0
	for _, player in players do
		local name, display = string.lower(player.Name), string.lower(player.DisplayName)
		if name == lowered or display == lowered then
			return player
		end
		if string.sub(name, 1, #lowered) == lowered or string.sub(display, 1, #lowered) == lowered then
			prefixed = player
			prefixCount += 1
		end
	end
	return if prefixCount == 1 then prefixed else nil
end

--------------------------------------------------------------------------------
-- Records
--------------------------------------------------------------------------------

local function runIsLive(): boolean
	return run ~= nil and phaseLive
end

local function isParticipant(player: Player): boolean
	local current = run
	return current ~= nil and table.find(current.participants, player) ~= nil
end

local function newRecord(player: Player): Record
	local record: Record = {
		state = "Lobby",
		health = MAX_HEALTH,
		downedCount = 0,
		bleedoutEndsAt = nil,
		bleedoutTimer = nil,
	}
	records[player] = record
	Attributes.set(player, P.LifeState, record.state)
	Attributes.set(player, P.DownedCount, 0)
	Attributes.set(player, P.BleedoutEndsAt, nil)
	return record
end

local function recordOf(player: Player): Record
	return records[player] or newRecord(player)
end

local function applyHealth(player: Player, record: Record)
	local shown = LifeStateService.humanoidHealth(record.state, record.health)
	local humanoid = Instances.characterHumanoid(player)
	if shown == nil or not humanoid then
		return
	end
	local current = humanoid.Health
	-- A dead Humanoid never comes back: a living state waits for the next character (CharacterSpawned applies it).
	if current == shown or (current <= 0 and shown > 0) then
		return
	end
	humanoid.Health = shown
end

local function cancelBleedout(player: Player, record: Record)
	local timer = record.bleedoutTimer
	record.bleedoutTimer = nil
	if timer then
		clock.cancel(timer)
	end
	record.bleedoutEndsAt = nil
	Attributes.set(player, P.BleedoutEndsAt, nil)
end

-- Writes the life state (attribute first, so every reader downstream sees it), refreshes PlayerStateService, and
-- fires StateChanged when it changed.
local function writeState(player: Player, record: Record, state: Enums.LifeState)
	local previous: Enums.LifeState = record.state
	-- A boolean, not a direct comparison: refining one union by another widens both to string.
	local changed = previous ~= state
	record.state = state
	Attributes.set(player, P.LifeState, state)
	PlayerStateService.Refresh(player)
	if changed then
		stateChanged:Fire(player, state, previous)
	end
end

local function setDownedCount(player: Player, record: Record, count: number)
	record.downedCount = count
	Attributes.set(player, P.DownedCount, count)
end

local function playGasp(player: Player)
	local root = Instances.characterRoot(player)
	if root then
		AudioService.PlayOn(GASP_PRESET, root)
	end
end

--------------------------------------------------------------------------------
-- Transitions
--------------------------------------------------------------------------------

-- Replaces the time source (specs pass a fake clock; nil restores server time + task.delay).
function LifeStateService.SetClock(fake: Clock?)
	clock = fake or realClock
end

function LifeStateService.GetState(player: Player): Enums.LifeState
	local record = records[player]
	return if record then record.state else "Lobby"
end

-- Alive or Downed.
function LifeStateService.IsPlaying(player: Player): boolean
	return LifeStateService.isPlayingState(LifeStateService.GetState(player))
end

-- Authoritative health (Humanoid.Health shows it clamped: at least 1 while Alive, 1 while Downed, 0 when Dead).
function LifeStateService.GetHealth(player: Player): number
	local record = records[player]
	return if record then record.health else MAX_HEALTH
end

function LifeStateService.GetDownedCount(player: Player): number
	local record = records[player]
	return if record then record.downedCount else 0
end

-- Server time the bleedout of a Downed player ends (nil when not bleeding out).
function LifeStateService.GetBleedoutEndsAt(player: Player): number?
	local record = records[player]
	return if record then record.bleedoutEndsAt else nil
end

-- Kills `player` (Alive / Downed during a live run). Idempotent.
function LifeStateService.Execute(player: Player, cause: string)
	local record = records[player]
	if not record or not runIsLive() or not LifeStateService.isPlayingState(record.state) then
		return
	end
	cancelBleedout(player, record)
	record.health = 0
	writeState(player, record, "Dead")
	PlayerStateService.PopOverride(player, OVERRIDE_TOKEN)
	applyHealth(player, record)
	log.info("%s executed (%s)", player.Name, cause)
	executed:Fire(player, cause)
end

-- Count, health, bleedout and the crawl override are in place before StateChanged fires, so its listeners see the
-- whole Downed state.
local function goDown(player: Player, record: Record, cause: string)
	setDownedCount(player, record, record.downedCount + 1)
	record.health = 1
	cancelBleedout(player, record)
	local endsAt = clock.now() + GameConfig.BleedoutSeconds
	record.bleedoutEndsAt = endsAt
	Attributes.set(player, P.BleedoutEndsAt, endsAt)
	record.bleedoutTimer = clock.delay(GameConfig.BleedoutSeconds, function()
		record.bleedoutTimer = nil
		if records[player] == record and record.state == "Downed" and record.bleedoutEndsAt == endsAt then
			LifeStateService.Execute(player, CAUSE_BLEEDOUT)
		end
	end)
	PlayerStateService.PushOverride(player, OVERRIDE_TOKEN, DOWNED_STATE)
	writeState(player, record, "Downed")
	applyHealth(player, record)
	playGasp(player)
	RunStatsService.Increment(player, "TimesDowned")
	log.info("%s downed (%s), %d down(s) this run", player.Name, cause, record.downedCount)
	downed:Fire(player, cause)
end

-- The lethal path: Downed the first time in a run, executed after that (or when already Downed).
function LifeStateService.Down(player: Player, cause: string)
	local record = records[player]
	if not record or not runIsLive() then
		return
	end
	local action = LifeStateService.lethalAction(record.state, record.downedCount)
	if action == "Down" then
		goDown(player, record, cause)
	elseif action == "Execute" then
		LifeStateService.Execute(player, cause)
	end
end

-- Deals `amount` damage to `player` (see the header). Lethal damage goes through Down.
function LifeStateService.Damage(player: Player, amount: number, cause: string)
	local record = records[player]
	if not record or not runIsLive() then
		return
	end
	local health, action = LifeStateService.damageResult(record.state, record.health, amount, record.downedCount)
	if action == "Ignore" then
		return
	end
	if action == "Hurt" then
		record.health = health
		applyHealth(player, record)
	elseif action == "Down" then
		goDown(player, record, cause)
	else
		LifeStateService.Execute(player, cause)
	end
	damaged:Fire(player, amount, cause)
end

-- Brings a Downed player back up at `healthFraction` of MaxHealth (default 0.5).
function LifeStateService.Revive(player: Player, healthFraction: number?)
	local record = records[player]
	if not record or record.state ~= "Downed" then
		return
	end
	cancelBleedout(player, record)
	record.health = LifeStateService.reviveHealth(healthFraction)
	writeState(player, record, "Alive")
	PlayerStateService.PopOverride(player, OVERRIDE_TOKEN)
	applyHealth(player, record)
	log.info("%s revived at %d", player.Name, math.round(record.health))
	revived:Fire(player)
end

-- Makes `player` Alive at `health` (default MaxHealth, clamped to [1, MaxHealth]) from any state.
function LifeStateService.SetAlive(player: Player, health: number?)
	local record = recordOf(player)
	local value = if health ~= nil and MathUtil.isFinite(health) then health else MAX_HEALTH
	cancelBleedout(player, record)
	record.health = math.clamp(value, 1, MAX_HEALTH)
	writeState(player, record, "Alive")
	PlayerStateService.PopOverride(player, OVERRIDE_TOKEN)
	applyHealth(player, record)
end

-- Back to the lobby: full health, no downs, no bleedout.
function LifeStateService.SetLobby(player: Player)
	local record = recordOf(player)
	cancelBleedout(player, record)
	record.health = MAX_HEALTH
	setDownedCount(player, record, 0)
	writeState(player, record, "Lobby")
	PlayerStateService.PopOverride(player, OVERRIDE_TOKEN)
	applyHealth(player, record)
end

-- P8: the player watches teammates (eliminated or a late joiner). Their character, if any, is left alone.
function LifeStateService.SetSpectating(player: Player)
	local record = recordOf(player)
	cancelBleedout(player, record)
	writeState(player, record, "Spectating")
	PlayerStateService.PopOverride(player, OVERRIDE_TOKEN)
end

--------------------------------------------------------------------------------
-- Dev commands
--------------------------------------------------------------------------------

local function describe(player: Player): string
	local record = recordOf(player)
	return string.format("%s: %s %d/%d", player.Name, record.state, math.round(record.health), MAX_HEALTH)
end

local function respawnDead(player: Player)
	local current = run
	local slot = if current then table.find(current.participants, player) or 1 else 1
	local level = ReplicatedStorage:GetAttribute(Attributes.Match.CurrentLevel)
	local layoutId: Enums.LayoutId = CharacterService.recoveryLayout(
		RunLifecycleService.GetPhase(),
		true,
		if type(level) == "string" then level else nil
	)
	LifeStateService.SetAlive(player, LifeStateService.reviveHealth(DEV_REVIVE_FRACTION))
	task.spawn(CharacterService.Spawn, player, CharacterService.SpawnCFrame(layoutId, slot))
end

-- Runs one of this service's dev commands for `caller` and returns the reply (DevToolsService sends it).
function LifeStateService.RunDevCommand(caller: Player, command: string, args: { string }): string
	local name = string.lower(command)
	local targetArg = if name == "hurt" then args[2] else args[1]
	local target = caller
	if targetArg ~= nil then
		local found = LifeStateService.findPlayer(targetArg, Players:GetPlayers())
		if not found then
			return string.format("no single player matches %q", targetArg)
		end
		target = found
	end
	if not runIsLive() then
		return "no run in progress"
	end
	if not isParticipant(target) then
		return target.Name .. " is not in this run"
	end
	local state = LifeStateService.GetState(target)
	if name == "hurt" then
		local amount = tonumber(args[1])
		if amount == nil or not MathUtil.isFinite(amount) or amount <= 0 then
			return "usage: hurt <amount> [player]"
		end
		LifeStateService.Damage(target, amount, CAUSE_DEV)
	elseif name == "down" then
		LifeStateService.Down(target, CAUSE_DEV)
	elseif name == "kill" then
		LifeStateService.Execute(target, CAUSE_DEV)
	elseif name == "revive" then
		if state == "Downed" then
			LifeStateService.Revive(target)
		elseif state == "Dead" or state == "Spectating" then
			respawnDead(target)
			return describe(target) .. " (respawning at the level entry)"
		else
			return describe(target) .. " (not down)"
		end
	elseif name == "heal" then
		if state == "Alive" then
			LifeStateService.SetAlive(target, MAX_HEALTH)
		elseif state == "Downed" then
			LifeStateService.Revive(target, 1)
		else
			return describe(target) .. " (cannot heal)"
		end
	else
		return "unknown life command " .. name
	end
	return describe(target)
end

local function registerDevCommands()
	local entries: { { name: string, help: string } } = {
		{ name = "hurt", help = "hurt <amount> [player]: damage yourself (or a player)" },
		{ name = "down", help = "down [player]: down yourself (executes if already downed once)" },
		{ name = "revive", help = "revive [player]: revive a downed player, or respawn a dead one" },
		{ name = "kill", help = "kill [player]: execute yourself (or a player)" },
		{ name = "heal", help = "heal [player]: restore full health" },
	}
	for _, entry in entries do
		local command = entry.name
		DevToolsService.Register(command, entry.help, function(player: Player, args: { string }): string?
			return LifeStateService.RunDevCommand(player, command, args)
		end)
	end
end

--------------------------------------------------------------------------------
-- Recovery + lifecycle
--------------------------------------------------------------------------------

-- The CharacterService recovery handler (registered in Init): true when this service handled the recovery.
function LifeStateService.HandleRecovery(
	player: Player,
	_model: Model?,
	reason: CharacterService.RecoveryReason
): boolean
	local decision =
		LifeStateService.recoveryDecision(reason, runIsLive(), isParticipant(player), LifeStateService.GetState(player))
	if decision == "Execute" then
		LifeStateService.Execute(player, CAUSE_FELL)
		return true
	end
	return decision == "Keep"
end

local function onCharacterSpawned(player: Player, _model: Model)
	local record = records[player]
	if not record or record.state == "Dead" or record.state == "Spectating" then
		return
	end
	applyHealth(player, record)
end

function LifeStateService.Init()
	if initialized then
		return
	end
	initialized = true
	CharacterService.SetRecoveryHandler(LifeStateService.HandleRecovery)
	serviceTrove:Connect(Players.PlayerAdded, function(player: Player)
		recordOf(player)
	end)
	serviceTrove:Add(CharacterService.CharacterSpawned:Connect(onCharacterSpawned))
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(function(phase: Enums.MatchPhase)
		phaseLive = run ~= nil and (phase == "Deploying" or phase == "InRun")
	end))
	serviceTrove:Add(LoadoutService.SyringeUsed:Connect(function(player: Player, mode: Enums.SyringeMode)
		if mode == "SelfRevive" then
			LifeStateService.Revive(player, SYRINGE_REVIVE_FRACTION)
		end
	end))
	serviceTrove:Add(PlayerStateService.OxygenDepleted:Connect(function(player: Player)
		LifeStateService.Down(player, CAUSE_DROWNED)
	end))
	registerDevCommands()
end

function LifeStateService.Start()
	for _, player in Players:GetPlayers() do
		recordOf(player)
	end
end

function LifeStateService.BeginRun(ctx: Types.RunContext)
	run = ctx
	phaseLive = true
	for _, player in ctx.participants do
		local record = recordOf(player)
		cancelBleedout(player, record)
		setDownedCount(player, record, 0)
		record.health = MAX_HEALTH
		writeState(player, record, "Alive")
		PlayerStateService.PopOverride(player, OVERRIDE_TOKEN)
		applyHealth(player, record)
	end
end

function LifeStateService.EndRun()
	for player in table.clone(records) do
		LifeStateService.SetLobby(player)
	end
	run = nil
	phaseLive = false
end

function LifeStateService.OnPlayerRemoving(player: Player)
	local record = records[player]
	if not record then
		return
	end
	local timer = record.bleedoutTimer
	record.bleedoutTimer = nil
	if timer then
		clock.cancel(timer)
	end
	records[player] = nil
end

return LifeStateService
