--!strict
-- LoadoutService: the server side of loadout perks (Config/PerkConfig).
--
-- Perks. A player's perks are read live from the Player.Loadout attribute through PerkConfig.parseLoadout (known
-- PerkIds only, de-duplicated, in Enums.PerkId order), so the server and the client (PromptRenderer, HUD) apply the
-- same PerkConfig rules to the same attribute and always agree:
--   HoldSeconds(player, kind, baseHold)  PerkConfig.holdSeconds: the Rusty Screwdriver shortens Unscrew to 1.2 s
--                                        (InteractionService's default hold time for every prompt)
--   BatteryCapacity(player)              PerkConfig.batteryCapacity: the Lithium Cell gives +50 % (FlashlightService
--                                        sizes the battery with it at BeginRun and on every Loadout change)
-- P8's lobby (PerkShopService) writes Player.Loadout before a run; the `loadout` dev command writes it for testing.
-- LoadoutChanged(player, perks) fires whenever the attribute changes. The Adrenaline Syringe is sold and equipped like
-- the others; what it does in a run is being redesigned (docs/design/game-spec-v2.md 3.3). This module requires no
-- Player-layer module.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PerkConfig = require(ReplicatedStorage.Shared.Config.PerkConfig)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)

local P = Attributes.Player

local ALL_PERKS = "all"
local NO_PERKS = "none"

local LoadoutService = {}

LoadoutService.Name = "LoadoutService"

local loadoutChanged: Signal.Signal<Player, { Enums.PerkId }> = Signal.new()

-- (player, perks) whenever Player.Loadout changes.
LoadoutService.LoadoutChanged = loadoutChanged

local serviceTrove = Trove.new()
local playerTroves: { [Player]: Trove.Trove } = {}

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Loadout.spec.luau)
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Mutations
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if playerTroves[player] then
		return
	end
	local trove = serviceTrove:Extend()
	playerTroves[player] = trove
	trove:Connect(player:GetAttributeChangedSignal(P.Loadout), function()
		loadoutChanged:Fire(player, LoadoutService.GetPerks(player))
	end)
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
	-- (during a run FlashlightService resizes the battery from LoadoutChanged at once)
	LoadoutService.SetLoadout(player, perks)
	return string.format(
		"loadout: %s (hold Unscrew %.1fs, battery %g)",
		if #perks > 0 then table.concat(perks, ", ") else NO_PERKS,
		LoadoutService.HoldSeconds(player, "Unscrew", GameConfig.UnscrewSeconds),
		LoadoutService.BatteryCapacity(player)
	)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function LoadoutService.Init()
	serviceTrove:Connect(Players.PlayerAdded, onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	DevToolsService.Register("loadout", "loadout [perk ...|all|none]: equip perks on yourself", loadoutCommand)
end

function LoadoutService.OnPlayerRemoving(player: Player)
	local trove = playerTroves[player]
	playerTroves[player] = nil
	if trove then
		serviceTrove:Remove(trove)
	end
end

return LoadoutService
