--!strict
-- Loadout perks. Bought with SurvivalCredits as stock; one unit is consumed when a run deploys with it equipped.

export type PerkSpec = {
	id: string,
	cost: number,
	maxEquipped: number,
	unscrewSeconds: number?,
	batteryCapacityMultiplier: number?,
	syringeCharges: number?,
}

local PerkConfig = table.freeze({
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
})

return PerkConfig
