--!strict
-- LoadoutService's perk rules. Loadout parsing (known ids, de-duplicated, Enums.PerkId order) feeds hold seconds
-- (the screwdriver shortens Unscrew only, never lengthens a hold), battery capacity (the lithium cell's +50 %) and
-- syringe charges. Syringe rules: SelfRevive only while Downed, Stamina only while Alive, a charge needed; an
-- accepted use spends the charge before SyringeUsed fires. BeginRun hands participants their charges; the dev
-- command's argument parsing and the canonical Loadout attribute.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PerkConfig = require(ReplicatedStorage.Shared.Config.PerkConfig)
local Types = require(ReplicatedStorage.Shared.Types)
local LoadoutService = require(ServerScriptService.Services.Player.LoadoutService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local P = Attributes.Player

local OTHER_KINDS: { Enums.PromptKind } = { "Kick", "TrapPry", "TrapRescue", "Revive", "Pickup", "Hide", "Floodlight" }

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

local function runContext(participants: { Player }): Types.RunContext
	return {
		runId = "loadout-spec",
		seed = 5,
		difficulty = "Standard",
		participants = participants,
		startedAt = Workspace:GetServerTimeNow(),
	}
end

local function verdict(ok: boolean, reason: string?): string
	return if ok then "ok" else tostring(reason)
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

	["syringe: SelfRevive while Downed, Stamina while Alive, a charge needed"] = function(t: Expect)
		local cases: { { mode: string, state: string, charges: number, expected: string } } = {
			{ mode = "SelfRevive", state = "Downed", charges = 1, expected = "ok" },
			{ mode = "Stamina", state = "Alive", charges = 1, expected = "ok" },
			{ mode = "Stamina", state = "Alive", charges = 3, expected = "ok" },
			{ mode = "SelfRevive", state = "Alive", charges = 1, expected = "NotDowned" },
			{ mode = "SelfRevive", state = "Dead", charges = 1, expected = "NotDowned" },
			{ mode = "Stamina", state = "Downed", charges = 1, expected = "NotAlive" },
			{ mode = "Stamina", state = "Lobby", charges = 1, expected = "NotAlive" },
			{ mode = "SelfRevive", state = "Downed", charges = 0, expected = "NoCharges" },
			{ mode = "Stamina", state = "Alive", charges = 0.5, expected = "NoCharges" },
			{ mode = "Stamina", state = "Alive", charges = 0 / 0, expected = "NoCharges" },
			{ mode = "Adrenaline", state = "Alive", charges = 1, expected = "UnknownMode" },
		}
		for _, case in cases do
			t.eq(
				verdict(LoadoutService.syringeVerdict(case.mode, case.state, case.charges)),
				case.expected,
				string.format("%s while %s with %s", case.mode, case.state, tostring(case.charges))
			)
		end
	end,

	["syringe use: the charge is spent before SyringeUsed fires"] = function(t: Expect)
		local p = player("AdrenalineSyringe", "Downed")
		p:SetAttribute(P.SyringeCharges, 1)
		local seen: { string } = {}
		local connection = LoadoutService.SyringeUsed:Connect(function(who: Player, mode: Enums.SyringeMode)
			if who == p then
				table.insert(seen, string.format("%s:%d", mode, LoadoutService.GetSyringeCharges(who)))
			end
		end)
		t.eq(verdict(LoadoutService.UseSyringe(p, "Stamina")), "NotAlive", "Stamina while Downed")
		t.eq(LoadoutService.GetSyringeCharges(p), 1, "a refusal spends nothing")
		t.eq(verdict(LoadoutService.UseSyringe(p, "SelfRevive")), "ok")
		t.eq(LoadoutService.GetSyringeCharges(p), 0)
		t.eq(verdict(LoadoutService.UseSyringe(p, "SelfRevive")), "NoCharges")
		connection:Disconnect()
		t.eq(table.concat(seen, ","), "SelfRevive:0", "fired once, after the decrement")
		p:Destroy()
	end,

	["BeginRun: participants get their perks' charges"] = function(t: Expect)
		local withSyringe = player("AdrenalineSyringe,LithiumCell", "Alive")
		local without = player("LithiumCell", "Alive")
		without:SetAttribute(P.SyringeCharges, 3)
		LoadoutService.BeginRun(runContext({ withSyringe, without }))
		t.eq(withSyringe:GetAttribute(P.SyringeCharges), PerkConfig.syringeCharges({ "AdrenalineSyringe" }))
		t.eq(withSyringe:GetAttribute(P.SyringeCharges), 1)
		t.eq(without:GetAttribute(P.SyringeCharges), 0, "no syringe equipped, none carried over")
		for _, p in { withSyringe, without } do
			LoadoutService.OnPlayerRemoving(p)
			p:Destroy()
		end
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
