--!strict
-- PerkShopService: the loadout perk shop at the supply-room console (spec §1). The only writer of Player.Loadout
-- outside the `loadout` dev command (through LoadoutService.SetLoadout, the canonical form every reader parses) and
-- of Player.PerkStock, the client's mirror of PlayerData.PerkStock (PerkConfig.encodeStock).
--
-- Buying. PerkPurchase { perk } (a RemoteFunction; Net admits it in the Lobby and Countdown phases, rate-limited)
-- is judged at the perks console (LobbyService.IsAtTerminal) with the player's data loaded, then spent in ONE
-- MatchAndDataService.Update: inside the mutate, against the draft, SurvivalCredits must cover PerkConfig's cost and
-- the stock must be under PerkConfig.MaxStock; then credits -= cost and PerkStock[perk] += 1 commit together or not
-- at all. Credits and stock can therefore never be lost or duplicated: a refused or failed Update (not enough
-- credits, a guest's read-only data) changes nothing, and two purchases racing each other are two separate Updates
-- the data layer serializes. The reply is Types.PerkPurchaseResult { ok, credits, stock, reason? } read back from the
-- committed data (reason: a Strings key: Lobby.NotEnoughCredits, Lobby.StockFull, Lobby.NotAtTerminal,
-- Lobby.DataLoading, Lobby.PurchaseFailed).
--
-- Equipping. LobbyAction EquipPerk / UnequipPerk (routed here by LobbyService.RegisterAction) at the perks console:
-- a perk can be equipped only while at least one unit is owned (each perk at most once: PerkConfig maxEquipped 1);
-- unequipping is always allowed there. MatchAndDataService.Deploy consumes one unit of every equipped perk when the
-- run starts. The loadout is never touched during a run (LoadoutService reads it live); when the lobby opens again,
-- when a player's data loads and after every purchase, Refresh mirrors the stock and drops equipped perks the player
-- no longer owns. Refusals are told to the player (Notify): Lobby.NoStock, Lobby.NotAtTerminal, Lobby.DataLoading.
--
-- The console. Its prompt (LobbyBuilder.Terminals.Perks, InteractionService kind Terminal; lobby phases, data loaded,
-- else Lobby.DataLoading) refreshes the player's mirror and opens the shop screen (LobbyService.OpenTerminal).
--
-- Pure rules (tests/Specs/Lobby.spec.luau): purchase (the mutate), equipVerdict, withPerk, withoutPerk, prune.
-- SetDependencies swaps the data layer, the phase, the console check, the loadout writer, the senders and the player
-- list, so specs buy and equip against a fake data layer that keeps the contract's atomic Update.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local LobbyBuilder = require(ReplicatedStorage.Shared.World.ProceduralWorldBuilder.LobbyBuilder)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local PerkConfig = require(ReplicatedStorage.Shared.Config.PerkConfig)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LoadoutService = require(ServerScriptService.Services.Player.LoadoutService)
local LobbyService = require(ServerScriptService.Services.Match.LobbyService)
local MatchAndDataService = require(ServerScriptService.Services.Match.MatchAndDataService)

local log = Log.new("PerkShop")

local P = Attributes.Player
local W = Attributes.World

-- The slice of MatchAndDataService the shop uses (the contract's GetData / Update).
export type MatchData = {
	GetData: (player: Player) -> Types.PlayerData?,
	Update: (player: Player, reason: string, mutate: (data: Types.PlayerData) -> boolean) -> boolean,
}

export type Dependencies = {
	data: MatchData?,
	phase: (() -> Enums.MatchPhase)?,
	atTerminal: ((player: Player) -> boolean)?, -- at the perks console
	setLoadout: ((player: Player, perks: { Enums.PerkId }) -> ())?,
	notify: ((player: Player, key: string) -> ())?,
	open: ((player: Player) -> ())?, -- opens the shop screen on the player's client
	players: (() -> { Player })?,
}

local TERMINAL_KIND: Enums.PromptKind = "Terminal"
local NOT_ENOUGH = "Lobby.NotEnoughCredits"
local STOCK_FULL = "Lobby.StockFull"
local NO_STOCK = "Lobby.NoStock"
local NOT_AT_TERMINAL = "Lobby.NotAtTerminal"
local DATA_LOADING = "Lobby.DataLoading"
local FAILED = "Lobby.PurchaseFailed"
local UNKNOWN = "Unknown"
local NOT_IN_LOBBY = "NotInLobby"

local LOBBY_PHASES: { [string]: boolean } = { Lobby = true, Countdown = true }

local PerkShopService = {}

PerkShopService.Name = "PerkShopService"
PerkShopService.Terminal = LobbyBuilder.Terminals.Perks

local serviceTrove = Trove.new()
local deps: Dependencies = {}
local initialized = false
local inLobby = false

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Lobby.spec.luau)
--------------------------------------------------------------------------------

-- Buys one `perk` on `draft` (a data draft inside Update): true when it applied, else the refusal (Strings key).
-- Nothing on the draft changes unless it applied.
function PerkShopService.purchase(draft: Types.PlayerData, perk: string): (boolean, string?)
	local spec = PerkConfig.get(perk)
	if not spec then
		return false, UNKNOWN
	end
	local owned = draft.PerkStock[perk] or 0
	if owned >= PerkConfig.MaxStock then
		return false, STOCK_FULL
	end
	if draft.SurvivalCredits < spec.cost then
		return false, NOT_ENOUGH
	end
	draft.SurvivalCredits -= spec.cost
	draft.PerkStock[perk] = owned + 1
	return true, nil
end

-- Whether `perk` may be equipped with `stock` owned. Every perk equips at most once (PerkConfig maxEquipped 1;
-- withPerk keeps one), so equipping one already worn is allowed and changes nothing.
function PerkShopService.equipVerdict(stock: { [string]: number }, perk: string): (boolean, string?)
	if PerkConfig.get(perk) == nil then
		return false, UNKNOWN
	end
	if (stock[perk] or 0) < 1 then
		return false, NO_STOCK
	end
	return true, nil
end

-- `equipped` with `perk` added (Enums.PerkId order, once).
function PerkShopService.withPerk(equipped: { Enums.PerkId }, perk: Enums.PerkId): { Enums.PerkId }
	local out: { Enums.PerkId } = {}
	for _, id: Enums.PerkId in Enums.PerkId do
		if id == perk or table.find(equipped, id) ~= nil then
			table.insert(out, id)
		end
	end
	return out
end

-- `equipped` without `perk`.
function PerkShopService.withoutPerk(equipped: { Enums.PerkId }, perk: Enums.PerkId): { Enums.PerkId }
	local out: { Enums.PerkId } = {}
	for _, id in equipped do
		if id ~= perk then
			table.insert(out, id)
		end
	end
	return out
end

-- `equipped` without the perks `stock` no longer holds, and whether anything was dropped.
function PerkShopService.prune(equipped: { Enums.PerkId }, stock: { [string]: number }): ({ Enums.PerkId }, boolean)
	local out: { Enums.PerkId } = {}
	for _, id in equipped do
		if (stock[id] or 0) >= 1 then
			table.insert(out, id)
		end
	end
	return out, #out ~= #equipped
end

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

local function data(): MatchData
	return deps.data or MatchAndDataService
end

local function currentPhase(): Enums.MatchPhase
	local fake = deps.phase
	return if fake then fake() else RunLifecycleService.GetPhase()
end

local function atTerminal(player: Player): boolean
	local fake = deps.atTerminal
	return if fake then fake(player) else LobbyService.IsAtTerminal(player, PerkShopService.Terminal)
end

local function setLoadout(player: Player, perks: { Enums.PerkId })
	local fake = deps.setLoadout
	if fake then
		fake(player, perks)
	else
		LoadoutService.SetLoadout(player, perks)
	end
end

local function notify(player: Player, key: string)
	local fake = deps.notify
	if fake then
		fake(player, key)
	else
		Net.Server.fire("Notify", player, { key = key, args = {} } :: Types.NotifyPayload)
	end
end

local function openScreen(player: Player)
	local fake = deps.open
	if fake then
		fake(player)
	else
		LobbyService.OpenTerminal(player, PerkShopService.Terminal)
	end
end

local function presentPlayers(): { Player }
	local fake = deps.players
	return if fake then fake() else Players:GetPlayers()
end

-- Swaps in fakes (nil restores every real dependency).
function PerkShopService.SetDependencies(fake: Dependencies?)
	deps = fake or {}
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local function equippedOf(player: Player): { Enums.PerkId }
	return PerkConfig.parseLoadout(player:GetAttribute(P.Loadout))
end

-- Mirrors `player`'s stock to Player.PerkStock and, in the lobby phases, drops equipped perks they no longer own.
function PerkShopService.Refresh(player: Player)
	local snapshot = data().GetData(player)
	if not snapshot then
		return
	end
	Attributes.set(player, P.PerkStock, PerkConfig.encodeStock(snapshot.PerkStock))
	if not LOBBY_PHASES[currentPhase()] then
		return
	end
	local equipped = equippedOf(player)
	local kept, dropped = PerkShopService.prune(equipped, snapshot.PerkStock)
	if dropped then
		setLoadout(player, kept)
	end
end

-- The PerkPurchase remote: buys one `perk` for `player` (see the header).
function PerkShopService.Purchase(player: Player, perk: string): Types.PerkPurchaseResult
	local function reply(ok: boolean, reason: string?): Types.PerkPurchaseResult
		local snapshot = data().GetData(player)
		return {
			ok = ok,
			credits = if snapshot then snapshot.SurvivalCredits else 0,
			stock = if snapshot then snapshot.PerkStock[perk] or 0 else 0,
			reason = reason,
		}
	end
	if not LOBBY_PHASES[currentPhase()] then
		return reply(false, FAILED)
	end
	if PerkConfig.get(perk) == nil then
		return reply(false, UNKNOWN)
	end
	if data().GetData(player) == nil then
		return reply(false, DATA_LOADING)
	end
	if not atTerminal(player) then
		return reply(false, NOT_AT_TERMINAL)
	end
	local refusal: string? = nil
	local committed = data().Update(player, "PerkPurchase:" .. perk, function(draft: Types.PlayerData): boolean
		local ok, reason = PerkShopService.purchase(draft, perk)
		refusal = reason
		return ok
	end)
	if committed then
		log.info("%s bought %s", player.Name, perk)
		PerkShopService.Refresh(player)
		return reply(true, nil)
	end
	return reply(false, refusal or FAILED)
end

-- Equips `perk` on `player` (at the console, owning one). Returns false and the refusal otherwise.
function PerkShopService.Equip(player: Player, perk: Enums.PerkId): (boolean, string?)
	if not LOBBY_PHASES[currentPhase()] then
		return false, NOT_IN_LOBBY
	end
	local snapshot = data().GetData(player)
	if not snapshot then
		notify(player, DATA_LOADING)
		return false, DATA_LOADING
	end
	if not atTerminal(player) then
		notify(player, NOT_AT_TERMINAL)
		return false, NOT_AT_TERMINAL
	end
	local equipped = equippedOf(player)
	local ok, refusal = PerkShopService.equipVerdict(snapshot.PerkStock, perk)
	if not ok then
		if refusal == NO_STOCK then
			notify(player, NO_STOCK)
		end
		return false, refusal
	end
	if table.find(equipped, perk) == nil then
		setLoadout(player, PerkShopService.withPerk(equipped, perk))
	end
	return true, nil
end

-- Unequips `perk` from `player` (at the console).
function PerkShopService.Unequip(player: Player, perk: Enums.PerkId): (boolean, string?)
	if not LOBBY_PHASES[currentPhase()] then
		return false, NOT_IN_LOBBY
	end
	if not atTerminal(player) then
		notify(player, NOT_AT_TERMINAL)
		return false, NOT_AT_TERMINAL
	end
	local equipped = equippedOf(player)
	if table.find(equipped, perk) ~= nil then
		setLoadout(player, PerkShopService.withoutPerk(equipped, perk))
	end
	return true, nil
end

-- MatchAndDataService.DataLoaded.
function PerkShopService.HandleDataLoaded(player: Player)
	PerkShopService.Refresh(player)
end

-- RunLifecycleService.PhaseChanged: the lobby opening again refreshes everyone (Deploy spent their equipped units).
function PerkShopService.HandlePhase(phase: Enums.MatchPhase)
	local lobbyNow = LOBBY_PHASES[phase] == true
	if lobbyNow and not inLobby then
		inLobby = true
		for _, player in presentPlayers() do
			PerkShopService.Refresh(player)
		end
	elseif not lobbyNow then
		inLobby = false
	end
end

-- The perks console's prompt.
PerkShopService.TerminalHandler = {
	kind = TERMINAL_KIND,
	filter = function(host: Instance, _prompt: ProximityPrompt): boolean
		return host:GetAttribute(W.AnchorId) == PerkShopService.Terminal
	end,
	canUse = function(player: Player, _prompt: ProximityPrompt, _host: Instance): (boolean, string?)
		if not LOBBY_PHASES[currentPhase()] then
			return false, NOT_IN_LOBBY
		end
		if data().GetData(player) == nil then
			return false, DATA_LOADING
		end
		return true, nil
	end,
	onComplete = function(player: Player, _prompt: ProximityPrompt, _host: Instance)
		PerkShopService.Refresh(player)
		openScreen(player)
	end,
} :: InteractionService.Handler

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onPurchase(player: Player, payload: any): Types.PerkPurchaseResult
	local request = payload :: Types.PerkPurchaseRequest
	return PerkShopService.Purchase(player, request.perk)
end

local function onEquip(player: Player, payload: Types.LobbyActionPayload)
	local perk: Enums.PerkId? = payload.perk
	if perk ~= nil then
		PerkShopService.Equip(player, perk)
	end
end

local function onUnequip(player: Player, payload: Types.LobbyActionPayload)
	local perk: Enums.PerkId? = payload.perk
	if perk ~= nil then
		PerkShopService.Unequip(player, perk)
	end
end

function PerkShopService.Init()
	if initialized then
		return
	end
	initialized = true
	Net.Server.onInvoke("PerkPurchase", onPurchase)
	LobbyService.RegisterAction("EquipPerk", onEquip)
	LobbyService.RegisterAction("UnequipPerk", onUnequip)
	serviceTrove:Add(InteractionService.Register(PerkShopService.TerminalHandler))
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(PerkShopService.HandlePhase))
	serviceTrove:Add(MatchAndDataService.DataLoaded:Connect(PerkShopService.HandleDataLoaded))
end

function PerkShopService.Start()
	PerkShopService.HandlePhase(RunLifecycleService.GetPhase())
end

-- Forgets the lobby state (specs).
function PerkShopService.Reset()
	inLobby = false
end

return PerkShopService
