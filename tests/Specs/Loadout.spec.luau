--!strict
-- LoadoutService's perk rules. Loadout parsing (known ids, de-duplicated, Enums.PerkId order) feeds hold seconds
-- (the screwdriver shortens Unscrew only, never lengthens a hold) and battery capacity (the lithium cell's +50 %);
-- the dev command's argument parsing and the canonical Loadout attribute.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PerkConfig = require(ReplicatedStorage.Shared.Config.PerkConfig)
local LoadoutService = require(ServerScriptService.Services.Player.LoadoutService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local P = Attributes.Player

local OTHER_KINDS: { Enums.PromptKind } = { "Kick", "TrapPry", "TrapRescue", "Revive", "Pickup", "Hide" }

local nextUserId = 7300

local function player(loadout: string?, lifeState: Enums.LifeState?): Player
	nextUserId += 1
	local p = Instance.new("Player")
	p.Name = "LoadoutSpec" .. nextUserId
	p.UserId = nextUserId
	if loadout then
		p:SetAttribute(P.Loadout, loadout)
	end
	if lifeState then
		p:SetAttribute(P.LifeState, lifeState)
	end
	return p
end

return {
	["perks: parsed live from the Loadout attribute"] = function(t: Expect)
		local p = player(" LithiumCell ,Bogus,RustyScrewdriver,LithiumCell")
		local perks = LoadoutService.GetPerks(p)
		t.eq(#perks, 2, "unknown ids and duplicates are dropped")
		t.eq(perks[1], "RustyScrewdriver", "Enums.PerkId order")
		t.eq(perks[2], "LithiumCell")
		t.truthy(LoadoutService.HasPerk(p, "LithiumCell"))
		t.falsy(LoadoutService.HasPerk(p, "AdrenalineSyringe"))
		p:SetAttribute(P.Loadout, "AdrenalineSyringe")
		t.truthy(LoadoutService.HasPerk(p, "AdrenalineSyringe"), "read live, never cached")
		t.falsy(LoadoutService.HasPerk(p, "LithiumCell"))
		p:SetAttribute(P.Loadout, 42)
		t.eq(#LoadoutService.GetPerks(p), 0, "a non-string attribute is an empty loadout")
		t.eq(#LoadoutService.GetPerks(player()), 0, "no attribute: no perks")
	end,

	["hold seconds: the screwdriver shortens Unscrew only"] = function(t: Expect)
		local plain = player("")
		local screwdriver = player("RustyScrewdriver")
		t.eq(LoadoutService.HoldSeconds(plain, "Unscrew", GameConfig.UnscrewSeconds), GameConfig.UnscrewSeconds)
		t.eq(LoadoutService.HoldSeconds(screwdriver, "Unscrew", GameConfig.UnscrewSeconds), 1.2)
		t.eq(LoadoutService.HoldSeconds(screwdriver, "Unscrew", 0.5), 0.5, "never lengthens a shorter hold")
		for _, kind: Enums.PromptKind in OTHER_KINDS do
			t.eq(LoadoutService.HoldSeconds(screwdriver, kind, 2.25), 2.25, kind .. " keeps its BaseHold")
		end
		t.eq(
			LoadoutService.HoldSeconds(screwdriver, "Unscrew", GameConfig.UnscrewSeconds),
			PerkConfig.holdSeconds("Unscrew", GameConfig.UnscrewSeconds, { "RustyScrewdriver" }),
			"the same rule the client's PromptRenderer applies"
		)
	end,

	["capacity: the lithium cell adds half a battery"] = function(t: Expect)
		t.eq(LoadoutService.BatteryCapacity(player("")), GameConfig.BatteryMax)
		t.eq(LoadoutService.BatteryCapacity(player("LithiumCell")), GameConfig.BatteryMax * 1.5)
		t.eq(LoadoutService.BatteryCapacity(player("RustyScrewdriver,AdrenalineSyringe")), GameConfig.BatteryMax)
	end,

	["dev command: perk arguments and the canonical Loadout attribute"] = function(t: Expect)
		local perks, unknown = LoadoutService.parsePerkArgs({ "lithiumcell", "RUSTYSCREWDRIVER", "LithiumCell" })
		t.eq(table.concat(perks, ","), "RustyScrewdriver,LithiumCell")
		t.eq(#unknown, 0)
		local all = LoadoutService.parsePerkArgs({ "all" })
		t.eq(#all, #Enums.PerkId)
		local none = LoadoutService.parsePerkArgs({ "none" })
		t.eq(#none, 0)
		local _, bad = LoadoutService.parsePerkArgs({ "LithiumCell", "Jetpack" })
		t.eq(table.concat(bad, ","), "Jetpack")

		local p = player()
		LoadoutService.SetLoadout(p, { "LithiumCell", "AdrenalineSyringe", "LithiumCell" })
		t.eq(p:GetAttribute(P.Loadout), "LithiumCell,AdrenalineSyringe", "Enums.PerkId order, no duplicates")
		t.eq(LoadoutService.BatteryCapacity(p), GameConfig.BatteryMax * 1.5)
		LoadoutService.SetLoadout(p, {})
		t.eq(p:GetAttribute(P.Loadout), "")
		p:Destroy()
	end,
}
