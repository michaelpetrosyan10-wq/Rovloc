--!strict
-- FlashlightService: battery authority. The only writer of the Player battery meter (Battery, BatteryRate, BatteryAt,
-- BatteryMax; Types.Meter) and of Player.FlashlightOn. Clients extrapolate the meter between writes, so it is
-- re-written only when its rate changes or something discrete happens (a toggle, a pickup, a resize, empty).
--
-- Toggle. FlashlightToggle { on } (Net: burst 6 at 4 per second, any phase) calls SetOn. Turning on needs charge
-- left and a player in play (never Dead or Spectating); a refusal for an empty battery tells the player
-- (Notify "Hud.BatteryEmpty", at most once every 2 s) and leaves FlashlightOn false for the client to reconcile to.
-- Turning off always succeeds. Dying or starting to spectate turns the light off.
--
-- Drain. A lit flashlight drains GameConfig.BatteryDrain per second while the match is InRun and its holder is
-- playing (Alive or Downed); everywhere else (lobby, results, a run's spectators) the rate is 0. The rate is
-- re-derived when the phase or the holder's life state changes. While it drains, the empty crossing is scheduled
-- from the extrapolation (task.delay); at the crossing the light goes out (FlashlightOn false, the meter written at
-- 0), the player gets Notify "Hud.BatteryEmpty", and Emptied fires.
--
-- Capacity. LoadoutService.BatteryCapacity(player) (the Lithium Cell: +50 %). BeginRun gives every participant a
-- full battery at that capacity, switched off; EndRun refills everyone (rate 0, off). A Loadout change resizes the
-- battery: full outside a run, charge kept (clamped) during one.
--
-- Pickups. A Pickup handler on hosts tagged BatteryPickup (InteractionService; Alive players): the host's Charge
-- (GameConfig.BatteryPickupCharge by default) is added, clamped to capacity, the Pickup cue plays at the prop for
-- everyone (AudioService) and the pickup model is destroyed. No Enums.StatKey counts batteries, so RunStats are not
-- touched.
--
-- Joining. Players get a full battery at their capacity, switched off. A participant who leaves mid-run gets their
-- charge back when they rejoin that run (kept by UserId until it ends), so reconnecting never refills a battery.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Attributes = require(ReplicatedStorage.Shared.Attributes)
local Enums = require(ReplicatedStorage.Shared.Enums)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Net = require(ReplicatedStorage.Shared.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Tags = require(ReplicatedStorage.Shared.Tags)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)
local Types = require(ReplicatedStorage.Shared.Types)

local AudioService = require(ServerScriptService.Services.Core.AudioService)
local DevToolsService = require(ServerScriptService.Services.Core.DevToolsService)
local RunLifecycleService = require(ServerScriptService.Services.Core.RunLifecycleService)
local InteractionService = require(ServerScriptService.Services.Player.InteractionService)
local LoadoutService = require(ServerScriptService.Services.Player.LoadoutService)

local log = Log.new("Flashlight")

local P = Attributes.Player
local W = Attributes.World

local EMPTY_NOTIFY = "Hud.BatteryEmpty"
local PICKUP_PRESET = "Pickup"
local EMPTY_EPSILON = 1e-3 -- charge at or below this counts as empty (timer and float slack)
local REFUSAL_NOTIFY_COOLDOWN = 2
local DRAIN_PHASE: Enums.MatchPhase = "InRun"

type Record = {
	trove: Trove.Trove,
	joined: boolean, -- onPlayerAdded ran (the record may exist earlier: a meter written before the join)
	generation: number, -- bumped on every meter write; a pending empty crossing from an older write is stale
	crossing: thread?,
	refusedAt: number?, -- os.clock() of the last "battery empty" refusal notice
}

-- A battery kept for a participant who left mid-run.
type Saved = { value: number, max: number }

local FlashlightService = {}

FlashlightService.Name = "FlashlightService"
FlashlightService.EmptyEpsilon = EMPTY_EPSILON

local toggled: Signal.Signal<Player, boolean> = Signal.new()
local emptied: Signal.Signal<Player> = Signal.new()

-- (player, on) whenever FlashlightOn changes (toggles, empty battery, forced off).
FlashlightService.Toggled = toggled
-- (player) when a lit flashlight runs dry.
FlashlightService.Emptied = emptied

local serviceTrove = Trove.new()
local records: { [Player]: Record } = {}
local saved: { [number]: Saved } = {} -- UserId -> battery of a participant who left the current run

--------------------------------------------------------------------------------
-- Pure rules (specs: tests/Specs/Flashlight.spec.luau)
--------------------------------------------------------------------------------

-- Whether a lit flashlight drains in match `phase` for a holder in `lifeState`.
function FlashlightService.isDraining(phase: string, lifeState: string): boolean
	return phase == DRAIN_PHASE and (lifeState == "Alive" or lifeState == "Downed")
end

-- The meter rate (per second) for a light that is `on`, given whether it drains.
function FlashlightService.drainRate(on: boolean, draining: boolean): number
	return if on and draining then -GameConfig.BatteryDrain else 0
end

-- Meter value at server time `now` (Types.Meter extrapolation, clamped to [0, max]).
function FlashlightService.meterValue(value: number, rate: number, at: number, max: number, now: number): number
	return math.clamp(value + rate * math.max(0, now - at), 0, max)
end

-- Seconds from a write of `value` at `rate` until the meter reaches 0 (nil when it never does).
function FlashlightService.emptyDelay(value: number, rate: number): number?
	if rate >= 0 or value <= 0 then
		return nil
	end
	return value / -rate
end

-- Charge after adding `amount` (negative drains) to `current`, clamped to [0, max].
function FlashlightService.addCharge(current: number, amount: number, max: number): number
	return math.clamp(current + amount, 0, math.max(0, max))
end

-- Whether a light with `battery` charge may switch on for a holder in `lifeState`.
function FlashlightService.canTurnOn(battery: number, lifeState: string): boolean
	return battery > EMPTY_EPSILON and lifeState ~= "Dead" and lifeState ~= "Spectating"
end

-- Battery after a capacity change to `max`: full outside a run, the current charge (clamped) during one.
function FlashlightService.resized(current: number, max: number, inRun: boolean): number
	if not inRun then
		return max
	end
	return math.clamp(current, 0, max)
end

--------------------------------------------------------------------------------
-- Meter
--------------------------------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function lifeStateOf(player: Player): string
	return Attributes.getString(player, P.LifeState, "Lobby")
end

local function recordOf(player: Player): Record
	local record = records[player]
	if not record then
		record = { trove = serviceTrove:Extend(), joined = false, generation = 0, crossing = nil, refusedAt = nil }
		records[player] = record
	end
	return record
end

local function notify(player: Player, key: string)
	if player.Parent ~= Players then
		return
	end
	local payload: Types.NotifyPayload = { key = key, args = {} }
	Net.Server.fire("Notify", player, payload)
end

-- `player`'s battery capacity as written (their loadout's capacity before the first write).
function FlashlightService.GetMax(player: Player): number
	local written = player:GetAttribute(P.BatteryMax)
	if type(written) == "number" and MathUtil.isFinite(written) and written > 0 then
		return written
	end
	return LoadoutService.BatteryCapacity(player)
end

function FlashlightService.GetBattery(player: Player): number
	return Attributes.readMeter(
		player,
		P.Battery,
		P.BatteryRate,
		P.BatteryAt,
		FlashlightService.GetMax(player),
		serverNow()
	)
end

function FlashlightService.IsOn(player: Player): boolean
	return Attributes.getBool(player, P.FlashlightOn, false)
end

-- Server time the lit flashlight runs dry at the current rate, or nil when it is not draining.
function FlashlightService.GetEmptyAt(player: Player): number?
	local rate = Attributes.getNumber(player, P.BatteryRate, 0)
	local delay = FlashlightService.emptyDelay(FlashlightService.GetBattery(player), rate)
	return if delay then serverNow() + delay else nil
end

local onCrossing: (player: Player, generation: number) -> ()

-- Writes the meter at `value` (capacity `max`), FlashlightOn (`on`, only with charge left) and the rate that follows,
-- then schedules the empty crossing when it drains.
local function write(player: Player, value: number, max: number, on: boolean)
	local record = recordOf(player)
	record.generation += 1
	local pending = record.crossing
	record.crossing = nil
	if pending and coroutine.status(pending) == "suspended" then
		task.cancel(pending)
	end
	local charge = math.clamp(value, 0, max)
	local lit = on and charge > EMPTY_EPSILON
	if not lit and charge <= EMPTY_EPSILON then
		charge = 0
	end
	local rate = FlashlightService.drainRate(
		lit,
		FlashlightService.isDraining(RunLifecycleService.GetPhase(), lifeStateOf(player))
	)
	local wasOn = FlashlightService.IsOn(player)
	Attributes.set(player, P.BatteryMax, max)
	Attributes.writeMeter(player, P.Battery, P.BatteryRate, P.BatteryAt, charge, rate, serverNow())
	Attributes.set(player, P.FlashlightOn, lit)
	local delay = FlashlightService.emptyDelay(charge, rate)
	if delay then
		record.crossing = task.delay(delay, onCrossing, player, record.generation)
	end
	if wasOn ~= lit then
		toggled:Fire(player, lit)
	end
end

-- The light ran dry: off, written at 0, the player told.
local function empty(player: Player)
	write(player, 0, FlashlightService.GetMax(player), false)
	notify(player, EMPTY_NOTIFY)
	emptied:Fire(player)
	log.debug("%s: flashlight battery empty", player.Name)
end

onCrossing = function(player: Player, generation: number)
	local record = records[player]
	if not record or record.generation ~= generation then
		return -- the meter was re-written since this crossing was scheduled
	end
	record.crossing = nil
	if not FlashlightService.IsOn(player) then
		return
	end
	local charge = FlashlightService.GetBattery(player)
	if charge <= EMPTY_EPSILON then
		empty(player)
	else
		-- The timer woke early: re-anchor the meter and schedule again.
		write(player, charge, FlashlightService.GetMax(player), true)
	end
end

-- Re-derives the rate of a lit flashlight (phase or life state changed); writes only when it actually changes.
local function rederive(player: Player)
	if not FlashlightService.IsOn(player) then
		return
	end
	local rate = FlashlightService.drainRate(
		true,
		FlashlightService.isDraining(RunLifecycleService.GetPhase(), lifeStateOf(player))
	)
	if rate ~= Attributes.getNumber(player, P.BatteryRate, 0) then
		write(player, FlashlightService.GetBattery(player), FlashlightService.GetMax(player), true)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Switches `player`'s flashlight. Returns false when turning on was refused (empty battery, or out of play).
function FlashlightService.SetOn(player: Player, on: boolean): boolean
	if FlashlightService.IsOn(player) == on then
		return true
	end
	local charge = FlashlightService.GetBattery(player)
	if on and not FlashlightService.canTurnOn(charge, lifeStateOf(player)) then
		return false
	end
	write(player, charge, FlashlightService.GetMax(player), on)
	return true
end

function FlashlightService.ForceOff(player: Player)
	FlashlightService.SetOn(player, false)
end

-- Adds `amount` charge (negative drains), clamped to [0, capacity]. A lit flashlight that reaches 0 goes out.
function FlashlightService.AddBattery(player: Player, amount: number)
	if type(amount) ~= "number" or not MathUtil.isFinite(amount) then
		log.warnThrottled("amount", 10, "AddBattery(%s): ignoring non-finite amount %s", player.Name, tostring(amount))
		return
	end
	local max = FlashlightService.GetMax(player)
	local charge = FlashlightService.addCharge(FlashlightService.GetBattery(player), amount, max)
	local on = FlashlightService.IsOn(player)
	if on and charge <= EMPTY_EPSILON then
		empty(player)
	else
		write(player, charge, max, on)
	end
end

-- Fills `player`'s battery to capacity (keeps the light as it is).
function FlashlightService.Refill(player: Player)
	local max = FlashlightService.GetMax(player)
	write(player, max, max, FlashlightService.IsOn(player))
end

-- Sets `player`'s capacity to their loadout's (full outside a run, charge kept during one).
function FlashlightService.ApplyCapacity(player: Player)
	local max = LoadoutService.BatteryCapacity(player)
	local charge =
		FlashlightService.resized(FlashlightService.GetBattery(player), max, RunLifecycleService.GetRun() ~= nil)
	write(player, charge, max, FlashlightService.IsOn(player))
end

--------------------------------------------------------------------------------
-- Battery pickups
--------------------------------------------------------------------------------

local function collect(player: Player, prompt: ProximityPrompt, host: Instance)
	local charge = Attributes.getNumber(host, W.Charge, GameConfig.BatteryPickupCharge)
	if not MathUtil.isFinite(charge) or charge < 0 then
		charge = GameConfig.BatteryPickupCharge
	end
	local position = InteractionService.PromptPosition(prompt)
	FlashlightService.AddBattery(player, charge)
	if position then
		AudioService.PlayAt(PICKUP_PRESET, position)
	end
	log.debug("%s picked up a battery (+%g)", player.Name, charge)
	host:Destroy()
end

-- The InteractionService handler for battery pickups (registered in Init).
FlashlightService.BatteryPickupHandler = table.freeze({
	kind = "Pickup",
	filter = function(host: Instance, _prompt: ProximityPrompt): boolean
		return host:HasTag(Tags.BatteryPickup)
	end,
	onComplete = collect,
} :: InteractionService.Handler)

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

local function onLifeStateChanged(player: Player)
	local lifeState = lifeStateOf(player)
	if lifeState == "Dead" or lifeState == "Spectating" then
		FlashlightService.ForceOff(player)
	else
		rederive(player)
	end
end

local function onPlayerAdded(player: Player)
	local record = recordOf(player)
	if record.joined then
		return
	end
	record.joined = true
	record.trove:Connect(player:GetAttributeChangedSignal(P.LifeState), function()
		onLifeStateChanged(player)
	end)
	local kept = saved[player.UserId]
	saved[player.UserId] = nil
	if kept then
		write(player, kept.value, kept.max, false)
	else
		local max = LoadoutService.BatteryCapacity(player)
		write(player, max, max, false)
	end
end

local function onToggle(player: Player, payload: any)
	local message = payload :: Types.FlashlightTogglePayload
	if FlashlightService.SetOn(player, message.on) or FlashlightService.GetBattery(player) > EMPTY_EPSILON then
		return
	end
	-- Pressing the switch on a dead battery: say so (throttled), the client reconciles to FlashlightOn false.
	local record = recordOf(player)
	local now = os.clock()
	local last = record.refusedAt
	if last == nil or now - last >= REFUSAL_NOTIFY_COOLDOWN then
		record.refusedAt = now
		notify(player, EMPTY_NOTIFY)
	end
end

local function batteryCommand(player: Player, args: { string }): string?
	local arg = if args[1] then string.lower(args[1]) else "full"
	local max = FlashlightService.GetMax(player)
	local target = if arg == "full" then max elseif arg == "empty" then 0 else tonumber(arg)
	if target == nil or not MathUtil.isFinite(target) then
		return "usage: battery [full|empty|<0-" .. tostring(max) .. ">]"
	end
	FlashlightService.AddBattery(player, target - FlashlightService.GetBattery(player))
	return string.format(
		"battery %.1f / %g (%s)",
		FlashlightService.GetBattery(player),
		max,
		if FlashlightService.IsOn(player) then "on" else "off"
	)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function FlashlightService.Init()
	Net.Server.on("FlashlightToggle", onToggle)
	serviceTrove:Add(InteractionService.Register(FlashlightService.BatteryPickupHandler))
	serviceTrove:Connect(Players.PlayerAdded, onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	serviceTrove:Add(RunLifecycleService.PhaseChanged:Connect(function()
		for _, player in Players:GetPlayers() do
			rederive(player)
		end
	end))
	serviceTrove:Add(LoadoutService.LoadoutChanged:Connect(function(player: Player)
		if records[player] then
			FlashlightService.ApplyCapacity(player)
		end
	end))
	DevToolsService.Register(
		"battery",
		"battery [full|empty|<charge>]: set your flashlight battery (a lit light that reaches 0 goes out)",
		batteryCommand
	)
end

function FlashlightService.BeginRun(ctx: Types.RunContext)
	table.clear(saved)
	for _, player in ctx.participants do
		local max = LoadoutService.BatteryCapacity(player)
		-- Every run starts with the torch on: the squad deploys into the dark already lit.
		write(player, max, max, true)
	end
end

function FlashlightService.EndRun()
	table.clear(saved)
	for _, player in Players:GetPlayers() do
		local max = LoadoutService.BatteryCapacity(player)
		write(player, max, max, false)
	end
end

function FlashlightService.OnPlayerRemoving(player: Player)
	local run = RunLifecycleService.GetRun()
	if run and table.find(run.participants, player) ~= nil then
		saved[player.UserId] = { value = FlashlightService.GetBattery(player), max = FlashlightService.GetMax(player) }
	end
	local record = records[player]
	records[player] = nil
	if record then
		local pending = record.crossing
		record.crossing = nil
		if pending and coroutine.status(pending) == "suspended" then
			task.cancel(pending)
		end
		serviceTrove:Remove(record.trove)
	end
end

return FlashlightService
