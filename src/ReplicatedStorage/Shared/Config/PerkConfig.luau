--!strict
-- Loadout perks. Bought with SurvivalCredits as stock; one unit is consumed when a run deploys with it equipped.
-- The pure rules below are shared: the server (LoadoutService, InteractionService) enforces them and the client
-- (PromptRenderer, HUD) predicts them from the same Player.Loadout attribute, so both always agree.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

export type PerkSpec = {
	id: string,
	cost: number,
	maxEquipped: number,
	unscrewSeconds: number?,
	batteryCapacityMultiplier: number?,
	syringeCharges: number?,
}

local Perks: { [string]: PerkSpec } = {
	RustyScrewdriver = table.freeze({
		id = "RustyScrewdriver",
		cost = 60,
		maxEquipped = 1,
		unscrewSeconds = 1.2, -- instead of GameConfig.UnscrewSeconds (3.5)
	} :: PerkSpec),
	LithiumCell = table.freeze({
		id = "LithiumCell",
		cost = 80,
		maxEquipped = 1,
		batteryCapacityMultiplier = 1.5,
	} :: PerkSpec),
	AdrenalineSyringe = table.freeze({
		id = "AdrenalineSyringe",
		cost = 120,
		maxEquipped = 1,
		syringeCharges = 1, -- one use: self-revive while Downed, or an instant stamina refill while Alive
	} :: PerkSpec),
}
table.freeze(Perks)

local PerkConfig = {}

PerkConfig.Perks = Perks

-- The perk spec for `id`, or nil for unknown ids.
function PerkConfig.get(id: string): PerkSpec?
	return Perks[id]
end

-- Parses a Player.Loadout attribute value ("RustyScrewdriver,LithiumCell") into known, de-duplicated PerkIds in
-- Enums.PerkId order. Anything else (unknown ids, non-strings) is ignored.
function PerkConfig.parseLoadout(value: unknown): { Enums.PerkId }
	local out: { Enums.PerkId } = {}
	if type(value) ~= "string" or value == "" then
		return out
	end
	local present: { [string]: boolean } = {}
	for entry in string.gmatch(value, "[^,]+") do
		present[(string.gsub(entry, "^%s*(.-)%s*$", "%1"))] = true
	end
	for _, id: Enums.PerkId in Enums.PerkId do
		if present[id] then
			table.insert(out, id)
		end
	end
	return out
end

function PerkConfig.has(perks: { Enums.PerkId }, id: Enums.PerkId): boolean
	return table.find(perks, id) ~= nil
end

-- Hold time of a prompt for a player with `perks`: the prompt's BaseHold, except Unscrew with the screwdriver.
function PerkConfig.holdSeconds(kind: string, baseHold: number, perks: { Enums.PerkId }): number
	if kind == "Unscrew" and PerkConfig.has(perks, "RustyScrewdriver") then
		local spec = Perks.RustyScrewdriver
		return math.min(baseHold, spec.unscrewSeconds or GameConfig.UnscrewSeconds)
	end
	return baseHold
end

-- Battery capacity for a player with `perks`.
function PerkConfig.batteryCapacity(perks: { Enums.PerkId }): number
	local multiplier = 1
	if PerkConfig.has(perks, "LithiumCell") then
		multiplier = Perks.LithiumCell.batteryCapacityMultiplier or 1
	end
	return GameConfig.BatteryMax * multiplier
end

-- Syringe charges a run starts with for a player with `perks`.
function PerkConfig.syringeCharges(perks: { Enums.PerkId }): number
	if PerkConfig.has(perks, "AdrenalineSyringe") then
		return Perks.AdrenalineSyringe.syringeCharges or 0
	end
	return 0
end

return table.freeze(PerkConfig)
