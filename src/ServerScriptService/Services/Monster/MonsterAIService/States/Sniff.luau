--!strict
-- Sniff: the breath check at a hiding spot, shared by InvestigateNoise and Search (docs/MONSTER.md 8.1). The Creature
-- stands at the spot's front, hunched, and peeks in through the game's inspector (RegisterLockerInspector:
-- HideSpotService, lockers, barrels and cabinets alike). The inspector yields until it has a verdict, so it runs in a
-- thread of its own: "Caught" is a ReachIn and a Locker catch on the occupant (when it still stands at the spot),
-- "HiddenSafe" and "Empty" move on; without an inspector it only looks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Types = require(ReplicatedStorage.Shared.Types)

local Brain = require(script.Parent.Parent.Brain)

type Context = Brain.Context

export type Inspection = { spot: Instance, started: number, verdict: Types.LockerVerdict? }

local log = Log.new("MonsterAI")

local SNIFF_SECONDS = 1.6
local INSPECT_TIMEOUT = GameConfig.BreathHoldMaxSeconds + 4
local SPOT_REACH = 8

local Sniff = {}

Sniff.SniffSeconds = SNIFF_SECONDS
Sniff.InspectTimeout = INSPECT_TIMEOUT

-- Starts the peek into `spot` (a hiding player's breath check takes a while). Nil without an inspector.
function Sniff.inspect(ctx: Context, spot: Instance): Inspection?
	local inspector = ctx.lockerInspector()
	if not inspector then
		return nil
	end
	local inspection: Inspection = { spot = spot, started = ctx.now(), verdict = nil }
	task.spawn(function()
		local ok, result = pcall(inspector, spot)
		local verdict: Types.LockerVerdict = if ok and (result == "Caught" or result == "HiddenSafe")
			then result
			else "Empty"
		if not ok then
			log.warnThrottled("inspector", 10, "the hiding spot inspector failed: %s", tostring(result))
		end
		inspection.verdict = verdict
		if verdict ~= "Caught" then
			return
		end
		local occupant = ctx.hideSpotOccupant(spot)
		local front = ctx.hideSpotFront(spot)
		local near = front ~= nil and (front.Position - ctx.body:GetPosition()).Magnitude <= SPOT_REACH
		if occupant and near then
			ctx.reachIn(occupant, spot)
		end
	end)
	return inspection
end

-- Whether a running peek still holds the Creature at the spot.
function Sniff.waiting(ctx: Context, inspection: Inspection?): boolean
	return inspection ~= nil and inspection.verdict == nil and ctx.now() - inspection.started < INSPECT_TIMEOUT
end

return table.freeze(Sniff)
