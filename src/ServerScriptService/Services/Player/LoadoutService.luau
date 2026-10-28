--!strict
-- LoadoutService: the server side of loadout perks (Config/PerkConfig). The only writer of Player.SyringeCharges.
--
-- Perks. A player's perks are read live from the Player.Loadout attribute through PerkConfig.parseLoadout (known
-- PerkIds only, de-duplicated, in Enums.PerkId order), so the server and the client (PromptRenderer, HUD) apply the
-- same PerkConfig rules to the same attribute and always agree:
--   HoldSeconds(player, kind, baseHold)  PerkConfig.holdSeconds: the Rusty Screwdriver shortens Unscrew to 1.2 s
--                                        (InteractionService's default hold time for every prompt)
--   BatteryCapacity(player)              PerkConfig.batteryCapacity: the Lithium Cell gives +50 % (FlashlightService
--                                        sizes the battery with it at BeginRun and on every Loadout change)
-- P8's lobby (PerkShopService) writes Player.Loadout before a run; the `loadout` dev command writes it for testing.
-- LoadoutChanged(player, perks) fires whenever the attribute changes.
--
-- Syringe. BeginRun gives every participant PerkConfig.syringeCharges(perks) charges (the Adrenaline Syringe: one);
-- everyone else, and everyone outside a run, has 0. UseSyringe { mode } arrives through Net, which already gated it
-- (InRun / Deploying, Alive / Downed, burst 2 at 0.5 per second). The request is judged here (syringeVerdict):
-- "SelfRevive" only while Downed, "Stamina" only while Alive, and a charge left. An accepted use decrements
-- SyringeCharges, then fires SyringeUsed(player, mode) and sends Notify "Hud.SyringeUsed" to the player. The effect
-- belongs to the services that own the state, which subscribe to SyringeUsed: LifeStateService revives on
-- "SelfRevive" and PlayerStateService refills stamina on "Stamina". This module requires no Player-layer module.
--
-- Leaving mid-run. A participant's remaining charges are kept by UserId until the run ends, so rejoining neither
-- refills nor loses the syringe.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Net = require(ReplicatedStorage.Shared.Net)
local PerkConfig = require(ReplicatedStorage.Shared.Config.PerkConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)

local log = Log.new("Loadout")

local P = Attributes.Player

local USED_NOTIFY = "Hud.SyringeUsed"
local ALL_PERKS = "all"
local NO_PERKS = "none"

-- The life state each syringe mode needs.
local SYRINGE_LIFE_STATE: { [string]: Enums.LifeState } = {
	SelfRevive = "Downed",
	Stamina = "Alive",
}

local LoadoutService = {}

LoadoutService.Name = "LoadoutService"

local syringeUsed: Signal.Signal<Player, Enums.SyringeMode> = Signal.new()
local loadoutChanged: Signal.Signal<Player, { Enums.PerkId }> = Signal.new()

-- (player, mode) after an accepted syringe use (the charge is already spent).
LoadoutService.SyringeUsed = syringeUsed
-- (player, perks) whenever Player.Loadout changes.
LoadoutService.LoadoutChanged = loadoutChanged

local serviceTrove = Trove.new()
local playerTroves: { [Player]: Trove.Trove } = {}
local savedCharges: { [number]: number } = {} -- UserId -> charges left by a participant who left mid-run

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Loadout.spec.luau)
--------------------------------------------------------------------------------

-- Whether a player in `lifeState` holding `charges` may use the syringe in `mode`; otherwise the refusal reason:
-- "UnknownMode", "NoCharges", "NotDowned" (SelfRevive needs Downed) or "NotAlive" (Stamina needs Alive).
function LoadoutService.syringeVerdict(mode: string, lifeState: string, charges: number): (boolean, string?)
	local required = SYRINGE_LIFE_STATE[mode]
	if required == nil then
		return false, "UnknownMode"
	end
	if not (charges >= 1) then
		return false, "NoCharges"
	end
	if lifeState ~= required then
		return false, if required == "Downed" then "NotDowned" else "NotAlive"
	end
	return true, nil
end

-- `loadout` dev-command arguments: perk ids in any case (or "all" / "none"). Returns the perks (Enums.PerkId order,
-- de-duplicated) and every argument that named no perk.
function LoadoutService.parsePerkArgs(args: { string }): ({ Enums.PerkId }, { string })
	local chosen: { [string]: boolean } = {}
	local unknown: { string } = {}
	for _, arg in args do
		local lowered = string.lower(arg)
		if lowered == ALL_PERKS then
			for _, id: Enums.PerkId in Enums.PerkId do
				chosen[id] = true
			end
			continue
		end
		if lowered == NO_PERKS then
			continue
		end
		local match: Enums.PerkId? = nil
		for _, id: Enums.PerkId in Enums.PerkId do
			if string.lower(id) == lowered then
				match = id
			end
		end
		if match then
			chosen[match] = true
		else
			table.insert(unknown, arg)
		end
	end
	local perks: { Enums.PerkId } = {}
	for _, id: Enums.PerkId in Enums.PerkId do
		if chosen[id] then
			table.insert(perks, id)
		end
	end
	return perks, unknown
end

--------------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------------

-- `player`'s equipped perks (live from Player.Loadout).
function LoadoutService.GetPerks(player: Player): { Enums.PerkId }
	return PerkConfig.parseLoadout(player:GetAttribute(P.Loadout))
end

function LoadoutService.HasPerk(player: Player, perk: Enums.PerkId): boolean
	return PerkConfig.has(LoadoutService.GetPerks(player), perk)
end

-- `player`'s hold time for a prompt of `kind` whose BaseHold is `baseHold`.
function LoadoutService.HoldSeconds(player: Player, kind: Enums.PromptKind, baseHold: number): number
	return PerkConfig.holdSeconds(kind, baseHold, LoadoutService.GetPerks(player))
end

-- `player`'s flashlight battery capacity.
function LoadoutService.BatteryCapacity(player: Player): number
	return PerkConfig.batteryCapacity(LoadoutService.GetPerks(player))
end

function LoadoutService.GetSyringeCharges(player: Player): number
	return math.max(0, math.floor(Attributes.getNumber(player, P.SyringeCharges, 0)))
end

--------------------------------------------------------------------------------
-- Mutations
--------------------------------------------------------------------------------

local function notify(player: Player, key: string)
	if player.Parent ~= Players then
		return
	end
	local payload: Types.NotifyPayload = { key = key, args = {} }
	Net.Server.fire("Notify", player, payload)
end

local function setCharges(player: Player, charges: number)
	Attributes.set(player, P.SyringeCharges, math.max(0, math.floor(charges)))
end

-- Writes `player`'s Loadout attribute in the canonical form the readers parse (Enums.PerkId order, no duplicates);
-- LoadoutChanged follows from the attribute change.
function LoadoutService.SetLoadout(player: Player, perks: { Enums.PerkId })
	local ids: { string } = {}
	for _, id: Enums.PerkId in Enums.PerkId do
		if PerkConfig.has(perks, id) then
			table.insert(ids, id)
		end
	end
	Attributes.set(player, P.Loadout, Attributes.joinList(ids))
end

-- Judges a syringe request; on success spends a charge, fires SyringeUsed and notifies the player.
function LoadoutService.UseSyringe(player: Player, mode: Enums.SyringeMode): (boolean, string?)
	local lifeState = Attributes.getString(player, P.LifeState, "Lobby")
	local charges = LoadoutService.GetSyringeCharges(player)
	local ok, refusal = LoadoutService.syringeVerdict(mode, lifeState, charges)
	if not ok then
		log.debug("%s: syringe %s refused (%s, %s, %d charges)", player.Name, mode, refusal, lifeState, charges)
		return false, refusal
	end
	setCharges(player, charges - 1)
	log.info("%s used the syringe (%s), %d charge(s) left", player.Name, mode, charges - 1)
	syringeUsed:Fire(player, mode)
	notify(player, USED_NOTIFY)
	return true, nil
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

local function participates(player: Player): boolean
	local run = RunLifecycleService.GetRun()
	return run ~= nil and table.find(run.participants, player) ~= nil
end

local function onPlayerAdded(player: Player)
	if playerTroves[player] then
		return
	end
	local trove = serviceTrove:Extend()
	playerTroves[player] = trove
	trove:Connect(player:GetAttributeChangedSignal(P.Loadout), function()
		loadoutChanged:Fire(player, LoadoutService.GetPerks(player))
	end)
	-- A participant rejoining the run they left gets their charges back (savedCharges only ever holds the current
	-- run's: BeginRun and EndRun clear it); everyone else starts empty.
	local saved = savedCharges[player.UserId]
	savedCharges[player.UserId] = nil
	setCharges(player, saved or 0)
end

--------------------------------------------------------------------------------
-- Dev command
--------------------------------------------------------------------------------

local function loadoutCommand(player: Player, args: { string }): string?
	local perks, unknown = LoadoutService.parsePerkArgs(args)
	if #unknown > 0 then
		return string.format(
			"unknown perk %s; usage: loadout [%s|%s|%s ...]",
			table.concat(unknown, ", "),
			ALL_PERKS,
			NO_PERKS,
			table.concat(Enums.PerkId, "|")
		)
	end
	LoadoutService.SetLoadout(player, perks)
	-- Testing convenience: during a run the new perks' run-start effects apply at once (FlashlightService resizes
	-- the battery from LoadoutChanged).
	if RunLifecycleService.GetRun() then
		setCharges(player, PerkConfig.syringeCharges(perks))
	end
	return string.format(
		"loadout: %s (hold Unscrew %.1fs, battery %g, syringe %d)",
		if #perks > 0 then table.concat(perks, ", ") else NO_PERKS,
		LoadoutService.HoldSeconds(player, "Unscrew", GameConfig.UnscrewSeconds),
		LoadoutService.BatteryCapacity(player),
		LoadoutService.GetSyringeCharges(player)
	)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onUseSyringe(player: Player, payload: any)
	local message = payload :: Types.UseSyringePayload
	LoadoutService.UseSyringe(player, message.mode)
end

function LoadoutService.Init()
	Net.Server.on("UseSyringe", onUseSyringe)
	serviceTrove:Connect(Players.PlayerAdded, onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	DevToolsService.Register(
		"loadout",
		"loadout [perk ...|all|none]: equip perks on yourself (during a run the syringe charges follow at once)",
		loadoutCommand
	)
end

function LoadoutService.BeginRun(ctx: Types.RunContext)
	table.clear(savedCharges)
	for _, player in Players:GetPlayers() do
		if table.find(ctx.participants, player) == nil then
			setCharges(player, 0)
		end
	end
	for _, player in ctx.participants do
		setCharges(player, PerkConfig.syringeCharges(LoadoutService.GetPerks(player)))
	end
end

function LoadoutService.EndRun()
	table.clear(savedCharges)
	for _, player in Players:GetPlayers() do
		setCharges(player, 0)
	end
end

function LoadoutService.OnPlayerRemoving(player: Player)
	if participates(player) then
		savedCharges[player.UserId] = LoadoutService.GetSyringeCharges(player)
	end
	local trove = playerTroves[player]
	playerTroves[player] = nil
	if trove then
		serviceTrove:Remove(trove)
	end
end

return LoadoutService
