--!strict
-- FlashlightService's battery. Drain: only a lit light drains, only while the match is InRun and its holder is
-- playing, at GameConfig.BatteryDrain. Meter: extrapolation clamps to [0, max], and the scheduled empty crossing is
-- exactly where the extrapolation reaches 0. Pickups: charge clamps to capacity. Rules: an empty battery or an
-- out-of-play holder refuses to switch on; a capacity change refills outside a run and keeps the charge inside one.
-- Service: the battery pickup handler serves BatteryPickup hosts only; SetOn / AddBattery / ForceOff / ApplyCapacity
-- and BeginRun drive a player's attributes (no run in the harness, so nothing drains here).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Types = require(ReplicatedStorage.Shared.Types)
local FlashlightService = require(ServerScriptService.Services.Player.FlashlightService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local SpecRunner = require(script.Parent.Parent.SpecRunner)

type Expect = SpecRunner.Expect

local P = Attributes.Player
local W = Attributes.World

local PLAYING: { Enums.LifeState } = { "Alive", "Downed" }
local NOT_PLAYING: { Enums.LifeState } = { "Lobby", "Dead", "Spectating" }
local OTHER_PHASES: { Enums.MatchPhase } = { "Lobby", "Countdown", "Deploying", "RunEnded", "Results", "Resetting" }

local nextUserId = 7100

local function player(loadout: string?): Player
	nextUserId += 1
	local p = Instance.new("Player")
	p.Name = "FlashlightSpec" .. nextUserId
	p.UserId = nextUserId
	p:SetAttribute(P.Loadout, loadout or "")
	return p
end

local function runContext(participants: { Player }): Types.RunContext
	return {
		runId = "flashlight-spec",
		seed = 11,
		difficulty = "Standard",
		participants = participants,
		startedAt = Workspace:GetServerTimeNow(),
	}
end

return {
	["drain: only a lit light drains, only InRun, only for a playing holder"] = function(t: Expect)
		for _, state: Enums.LifeState in PLAYING do
			t.truthy(FlashlightService.isDraining("InRun", state), state .. " drains in a run")
		end
		for _, state: Enums.LifeState in NOT_PLAYING do
			t.falsy(FlashlightService.isDraining("InRun", state), state .. " never drains")
		end
		for _, phase: Enums.MatchPhase in OTHER_PHASES do
			t.falsy(FlashlightService.isDraining(phase, "Alive"), "no drain in " .. phase)
		end
		t.eq(FlashlightService.drainRate(true, true), -GameConfig.BatteryDrain)
		t.eq(FlashlightService.drainRate(false, true), 0, "an unlit light")
		t.eq(FlashlightService.drainRate(true, false), 0, "outside a run")
	end,

	["meter: extrapolation clamps to [0, max]"] = function(t: Expect)
		local rate = -GameConfig.BatteryDrain
		t.near(FlashlightService.meterValue(50, rate, 10, 100, 20), 50 + rate * 10, 1e-9)
		t.eq(FlashlightService.meterValue(5, rate, 10, 100, 10_000), 0, "never below 0")
		t.eq(FlashlightService.meterValue(95, 3, 0, 100, 100), 100, "never above max")
		t.eq(FlashlightService.meterValue(40, rate, 10, 100, 5), 40, "a read before the write time does not run back")
		local probe = Instance.new("Folder")
		Attributes.writeMeter(probe, P.Battery, P.BatteryRate, P.BatteryAt, 70, rate, 10)
		t.eq(
			FlashlightService.meterValue(70, rate, 10, 100, 30),
			Attributes.readMeter(probe, P.Battery, P.BatteryRate, P.BatteryAt, 100, 30),
			"matches the clients' Attributes.readMeter"
		)
		probe:Destroy()
	end,

	["empty crossing: scheduled where the extrapolation reaches 0"] = function(t: Expect)
		local rate = -GameConfig.BatteryDrain
		local delay = FlashlightService.emptyDelay(100, rate)
		t.truthy(delay, "a draining light empties")
		local seconds = delay :: number
		t.near(seconds, 100 / GameConfig.BatteryDrain, 1e-9)
		t.truthy(seconds > 150 and seconds < 220, "about three minutes per full cell")
		t.near(FlashlightService.meterValue(100, rate, 40, 100, 40 + seconds), 0, 1e-9, "empty exactly then")
		t.truthy(FlashlightService.meterValue(100, rate, 40, 100, 40 + seconds - 0.1) > 0, "not before")
		t.eq(FlashlightService.emptyDelay(100, 0), nil, "a steady meter never crosses")
		t.eq(FlashlightService.emptyDelay(100, 2), nil, "a charging meter never crosses")
		t.eq(FlashlightService.emptyDelay(0, rate), nil, "already empty")
	end,

	["pickups: charge clamps to capacity"] = function(t: Expect)
		local charge = GameConfig.BatteryPickupCharge
		t.eq(FlashlightService.addCharge(20, charge, 100), 20 + charge)
		t.eq(FlashlightService.addCharge(80, charge, 100), 100, "clamped to max")
		t.eq(FlashlightService.addCharge(80, charge, 150), 125, "a lithium cell holds more")
		t.eq(FlashlightService.addCharge(10, -30, 100), 0, "drains stop at 0")
		t.eq(FlashlightService.addCharge(50, 0, 100), 50)
	end,

	["rules: switching on and resizing"] = function(t: Expect)
		t.truthy(FlashlightService.canTurnOn(1, "Alive"))
		t.truthy(FlashlightService.canTurnOn(1, "Downed"), "a downed player can still light the way")
		t.truthy(FlashlightService.canTurnOn(1, "Lobby"), "the lobby too (it never drains there)")
		t.falsy(FlashlightService.canTurnOn(0, "Alive"), "an empty battery")
		t.falsy(FlashlightService.canTurnOn(FlashlightService.EmptyEpsilon, "Alive"), "dregs count as empty")
		t.falsy(FlashlightService.canTurnOn(80, "Dead"))
		t.falsy(FlashlightService.canTurnOn(80, "Spectating"))
		t.eq(FlashlightService.resized(30, 150, false), 150, "outside a run: full at the new capacity")
		t.eq(FlashlightService.resized(30, 150, true), 30, "during a run: the charge is kept")
		t.eq(FlashlightService.resized(140, 100, true), 100, "clamped when the capacity shrinks")
	end,

	["pickup handler: serves BatteryPickup hosts only"] = function(t: Expect)
		local handler = FlashlightService.BatteryPickupHandler
		t.eq(handler.kind, "Pickup")
		local battery = Instance.new("Model")
		battery:AddTag(Tags.Interactable)
		battery:AddTag(Tags.BatteryPickup)
		local flask = Instance.new("Model")
		flask:AddTag(Tags.Interactable)
		flask:AddTag(Tags.ChemicalItem)
		local function prompt(parent: Instance): ProximityPrompt
			local p = Instance.new("ProximityPrompt")
			p:SetAttribute(W.PromptKind, "Pickup")
			p.Parent = parent
			return p
		end
		t.truthy(InteractionService.matches(handler, battery, prompt(battery)))
		t.falsy(InteractionService.matches(handler, flask, prompt(flask)), "flasks belong to another handler")
		t.eq(handler.canUse, nil, "Alive players only (the default)")
		battery:Destroy()
		flask:Destroy()
	end,

	["service: toggles, charge and capacity on a player"] = function(t: Expect)
		local p = player()
		t.eq(FlashlightService.GetMax(p), GameConfig.BatteryMax, "capacity from the loadout before any write")
		t.eq(FlashlightService.GetBattery(p), GameConfig.BatteryMax, "a fresh battery reads full")
		t.falsy(FlashlightService.IsOn(p))

		local toggles: { string } = {}
		local connection = FlashlightService.Toggled:Connect(function(who: Player, on: boolean)
			if who == p then
				table.insert(toggles, if on then "on" else "off")
			end
		end)
		t.truthy(FlashlightService.SetOn(p, true))
		t.truthy(FlashlightService.IsOn(p))
		t.eq(p:GetAttribute(P.FlashlightOn), true)
		t.eq(p:GetAttribute(P.BatteryRate), 0, "no run: no drain")
		t.eq(FlashlightService.GetEmptyAt(p), nil)
		t.truthy(FlashlightService.SetOn(p, true), "already on")

		FlashlightService.AddBattery(p, -30)
		t.near(FlashlightService.GetBattery(p), GameConfig.BatteryMax - 30, 1e-9)
		FlashlightService.AddBattery(p, 500)
		t.eq(FlashlightService.GetBattery(p), GameConfig.BatteryMax, "clamped")
		FlashlightService.AddBattery(p, 0 / 0)
		t.eq(FlashlightService.GetBattery(p), GameConfig.BatteryMax, "non-finite amounts are ignored")

		FlashlightService.AddBattery(p, -1000)
		t.eq(FlashlightService.GetBattery(p), 0)
		t.falsy(FlashlightService.IsOn(p), "a lit light that reaches 0 goes out")
		t.falsy(FlashlightService.SetOn(p, true), "an empty battery refuses")
		t.truthy(FlashlightService.SetOn(p, false), "off always works")

		FlashlightService.AddBattery(p, GameConfig.BatteryPickupCharge)
		t.eq(FlashlightService.GetBattery(p), GameConfig.BatteryPickupCharge)
		t.truthy(FlashlightService.SetOn(p, true))
		FlashlightService.ForceOff(p)
		t.falsy(FlashlightService.IsOn(p))

		p:SetAttribute(P.LifeState, "Dead")
		t.falsy(FlashlightService.SetOn(p, true), "out of play")
		p:SetAttribute(P.LifeState, "Alive")

		p:SetAttribute(P.Loadout, "LithiumCell")
		FlashlightService.ApplyCapacity(p)
		t.eq(FlashlightService.GetMax(p), GameConfig.BatteryMax * 1.5, "the lithium cell")
		t.eq(FlashlightService.GetBattery(p), GameConfig.BatteryMax * 1.5, "outside a run the resize refills")

		connection:Disconnect()
		t.eq(table.concat(toggles, ","), "on,off,on,off", "Toggled fires on every change and only then")
		FlashlightService.OnPlayerRemoving(p)
		p:Destroy()
	end,

	["service: BeginRun gives every participant a full, unlit battery at their capacity"] = function(t: Expect)
		local plain = player()
		local lithium = player("LithiumCell")
		FlashlightService.AddBattery(plain, -60)
		FlashlightService.SetOn(lithium, true)
		FlashlightService.BeginRun(runContext({ plain, lithium }))
		t.eq(FlashlightService.GetBattery(plain), GameConfig.BatteryMax)
		t.eq(FlashlightService.GetMax(lithium), GameConfig.BatteryMax * 1.5)
		t.eq(FlashlightService.GetBattery(lithium), GameConfig.BatteryMax * 1.5)
		t.falsy(FlashlightService.IsOn(lithium), "every run starts dark")
		t.eq(lithium:GetAttribute(P.BatteryRate), 0)
		for _, p in { plain, lithium } do
			FlashlightService.OnPlayerRemoving(p)
			p:Destroy()
		end
	end,
}
