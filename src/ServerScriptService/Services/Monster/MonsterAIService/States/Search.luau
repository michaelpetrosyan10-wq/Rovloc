--!strict
-- Search (docs/MONSTER.md 6.6): a chase lost its quarry (or someone slipped away from a hiding spot it was watching).
-- For U(12, 18) s the Creature checks the hiding spots within Search.Radius of the last seen point, in a seeded random
-- order, sniffing at each (the breath check, Sniff: lockers, barrels and cabinets alike); with none left it turns on
-- the spot, listening, until the time is up. Then it stalks on (Patrol). Seeing someone (WallChase), a High noise
-- (InvestigateNoise) or seeing someone hide (HidingResponse) breaks it off (the brain).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)

local Brain = require(script.Parent.Parent.Brain)
local Sniff = require(script.Parent.Sniff)

type Context = Brain.Context

type Run = {
	at: Vector3,
	phase: "Approach" | "Spots",
	spots: { Brain.HideSpot },
	index: number,
	stage: "Start" | "Travel" | "Hold",
	deadline: number,
	approachUntil: number,
	inspection: Sniff.Inspection?,
	turn: number,
}

local NAME: Enums.MonsterState = "Search"
local TUNING = CreatureConfig.Search
local ARRIVE = 2.5
local SPOT_ARRIVE = 1.2
local LOOK_SECONDS = 1.2
local LOOK_TURN = 2.1 -- radians either way, alternately
local APPROACH_SECONDS = 15

local Search = {}

Search.Name = NAME

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

local function runOf(ctx: Context): Run
	local run = runs[ctx]
	if not run then
		run = {
			at = Vector3.zero,
			phase = "Approach",
			spots = {},
			index = 1,
			stage = "Start",
			deadline = 0,
			approachUntil = 0,
			inspection = nil,
			turn = 0,
		}
		runs[ctx] = run
	end
	return run
end

-- A seeded shuffle (Fisher-Yates over `random`).
function Search.shuffled<T>(list: { T }, random: Random): { T }
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = random:NextInteger(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

function Search.enter(ctx: Context, _from: Enums.MonsterState)
	local run = runOf(ctx)
	local speed = ctx.speedOf(NAME)
	ctx.mover:SetSpeed(speed)
	ctx.body:SetWalkSpeed(speed)
	ctx.mover:SetRepathInterval(CreatureConfig.Repath.PatrolInterval / 2)
	ctx.body:Face(nil)
	if ctx.mover:Medium() == "Floor" then
		ctx.body:SetPose("Biped")
	end
	local at = ctx.searchFrom or ctx.body:GetPosition()
	run.at = at
	run.phase = "Approach"
	run.index = 1
	run.stage = "Start"
	run.inspection = nil
	run.turn = 0
	run.approachUntil = ctx.now() + APPROACH_SECONDS
	run.deadline = ctx.now() + ctx.random:NextNumber(TUNING.MinSeconds, TUNING.MaxSeconds)
	local spots = Search.shuffled(ctx.hideSpotsNear(at, TUNING.Radius), ctx.random)
	run.spots = {}
	for i = 1, math.min(#spots, TUNING.Spots) do
		table.insert(run.spots, spots[i])
	end
	ctx.mover:GoTo(at, { arrive = ARRIVE })
end

function Search.update(ctx: Context, _dt: number)
	local run = runOf(ctx)
	local mover = ctx.mover
	local busy = mover:Busy()
	local status = mover:Status()
	local now = ctx.now()
	if now > run.deadline then
		if not Sniff.waiting(ctx, run.inspection) then
			ctx.stateDone = true
		end
		return
	end
	if run.phase == "Approach" then
		if (busy or status == "Moving") and now < run.approachUntil then
			return
		end
		run.phase = "Spots"
		return
	end
	local spot = run.spots[run.index]
	if not spot then
		-- nothing left to check: it turns where it stands, listening
		if busy then
			return
		end
		run.turn += 1
		local look = ctx.body:GetCFrame().LookVector
		local a = (if run.turn % 2 == 0 then 1 else -1) * LOOK_TURN
		local turned =
			Vector3.new(look.X * math.cos(a) - look.Z * math.sin(a), 0, look.X * math.sin(a) + look.Z * math.cos(a))
		mover:Hold(LOOK_SECONDS, turned)
		return
	end
	if run.stage == "Start" then
		if busy then
			return
		end
		run.stage = "Travel"
		mover:GoTo(spot.front.Position, { arrive = SPOT_ARRIVE })
		return
	end
	if run.stage == "Travel" then
		if busy or status == "Moving" then
			return
		end
		if status == "Failed" or status == "Stuck" then
			run.index += 1
			run.stage = "Start"
			return
		end
		run.stage = "Hold"
		ctx.body:SetPose("Hunched")
		mover:Hold(Sniff.SniffSeconds, -spot.front.LookVector)
		run.inspection = Sniff.inspect(ctx, spot.id)
		return
	end
	if Sniff.waiting(ctx, run.inspection) or busy then
		return
	end
	run.index += 1
	run.stage = "Start"
	run.inspection = nil
	if mover:Medium() == "Floor" then
		ctx.body:SetPose("Biped")
	end
end

function Search.exit(ctx: Context, _to: Enums.MonsterState)
	local run = runOf(ctx)
	run.inspection = nil
	if ctx.mover:Medium() == "Floor" then
		ctx.body:SetPose("Biped")
	end
	ctx.body:Face(nil)
	ctx.searchFrom = nil
end

return table.freeze(Search)
