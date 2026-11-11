--!strict
-- InvestigateNoise (docs/MONSTER.md 6.4): the Creature goes to where it believes a noise came from (exact for loud
-- noises, blurred for quiet ones) at the InvestigateNoise pace (9), for at most APPROACH_SECONDS, then searches there
-- for U(6, 10) s: a look back the way it came, then the hiding spots nearest the spot (lockers, barrels, cabinets: up to
-- Investigate.Spots of them, within the search radius), sniffing at each (the breath check, Sniff). A louder (or equally
-- loud) noise re-targets it, and any noise while it searches; an approach that takes too long gives up. Nothing found
-- ends the state (Patrol).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)

local Brain = require(script.Parent.Parent.Brain)
local Sniff = require(script.Parent.Sniff)

type Context = Brain.Context

export type Step = { kind: "Look" | "Spot", position: Vector3, face: Vector3?, seconds: number, spot: Instance? }

type Run = {
	investigation: Brain.Investigation?,
	phase: "Approach" | "Search",
	steps: { Step },
	index: number,
	stage: "Start" | "Travel" | "Hold",
	deadline: number,
	approachUntil: number,
	inspection: Sniff.Inspection?,
}

local NAME: Enums.MonsterState = "InvestigateNoise"
local TUNING = CreatureConfig.Investigate
local LOOK_SECONDS = 1.4
local ARRIVE = 3
local SPOT_ARRIVE = 1.2
local APPROACH_SECONDS = 30
local SPOT_RADIUS = CreatureConfig.Search.Radius

local InvestigateNoise = {}

InvestigateNoise.Name = NAME
InvestigateNoise.ApproachSeconds = APPROACH_SECONDS

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

-- The search at `at`: a look back the way it came, then the nearest hiding spots (up to `max`).
function InvestigateNoise.searchPlan(at: Vector3, spots: { Brain.HideSpot }, look: Vector3, max: number): { Step }
	local steps: { Step } = {}
	local flat = Vector3.new(look.X, 0, look.Z)
	local back = if flat.Magnitude > 1e-3 then -flat.Unit else Vector3.new(0, 0, 1)
	table.insert(steps, { kind = "Look", position = at, face = back, seconds = LOOK_SECONDS, spot = nil })
	local near = table.clone(spots)
	table.sort(near, function(a: Brain.HideSpot, b: Brain.HideSpot): boolean
		return (a.front.Position - at).Magnitude < (b.front.Position - at).Magnitude
	end)
	for i = 1, math.min(#near, max) do
		local spot = near[i]
		table.insert(steps, {
			kind = "Spot",
			position = spot.front.Position,
			face = -spot.front.LookVector,
			seconds = Sniff.SniffSeconds,
			spot = spot.id,
		})
	end
	return steps
end

local function runOf(ctx: Context): Run
	local run = runs[ctx]
	if not run then
		run = {
			investigation = nil,
			phase = "Approach",
			steps = {},
			index = 1,
			stage = "Start",
			deadline = 0,
			approachUntil = 0,
			inspection = nil,
		}
		runs[ctx] = run
	end
	return run
end

local function begin(ctx: Context, run: Run, investigation: Brain.Investigation?)
	run.investigation = investigation
	run.phase = "Approach"
	run.steps = {}
	run.index = 1
	run.stage = "Start"
	run.inspection = nil
	run.approachUntil = ctx.now() + APPROACH_SECONDS
	ctx.body:SetPose("Biped")
	local goal = if investigation then investigation.position else ctx.body:GetPosition()
	ctx.mover:GoTo(goal, { arrive = ARRIVE })
end

local function startSearch(ctx: Context, run: Run, at: Vector3)
	run.phase = "Search"
	run.steps = InvestigateNoise.searchPlan(
		at,
		ctx.hideSpotsNear(at, SPOT_RADIUS),
		ctx.body:GetCFrame().LookVector,
		TUNING.Spots
	)
	run.index = 1
	run.stage = "Start"
	run.deadline = ctx.now() + ctx.random:NextNumber(TUNING.MinSeconds, TUNING.MaxSeconds)
end

local function nextStep(ctx: Context, run: Run)
	run.index += 1
	run.stage = "Start"
	run.inspection = nil
	ctx.body:SetPose("Biped")
end

local function startHold(ctx: Context, run: Run, step: Step)
	run.stage = "Hold"
	if step.kind == "Spot" then
		ctx.body:SetPose("Hunched")
	end
	ctx.mover:Hold(step.seconds, step.face)
	local spot = step.spot
	if step.kind == "Spot" and spot then
		run.inspection = Sniff.inspect(ctx, spot)
	end
end

function InvestigateNoise.enter(ctx: Context, _from: Enums.MonsterState)
	local speed = ctx.speedOf(NAME)
	ctx.mover:SetSpeed(speed)
	ctx.body:SetWalkSpeed(speed)
	ctx.mover:SetRepathInterval(CreatureConfig.Repath.PatrolInterval / 2)
	ctx.body:Face(nil)
	begin(ctx, runOf(ctx), ctx.investigation)
end

function InvestigateNoise.update(ctx: Context, _dt: number)
	local run = runOf(ctx)
	local current = run.investigation
	local heard = ctx.heard
	if heard and (current == nil or heard.rank >= current.rank or run.phase == "Search") then
		local fresh: Brain.Investigation =
			{ position = ctx.floorPointNear(heard.position), rank = heard.rank, at = heard.at }
		ctx.investigation = fresh
		begin(ctx, run, fresh)
		return
	end
	local mover = ctx.mover
	local busy = mover:Busy()
	local status = mover:Status()
	if run.phase == "Approach" then
		if ctx.now() > run.approachUntil then
			ctx.stateDone = true
			return
		end
		if busy or status == "Moving" then
			return
		end
		startSearch(ctx, run, if status == "Idle" and current then current.position else ctx.body:GetPosition())
		return
	end
	if ctx.now() > run.deadline then
		if not Sniff.waiting(ctx, run.inspection) then
			ctx.stateDone = true
		end
		return
	end
	local step = run.steps[run.index]
	if not step then
		ctx.stateDone = true
		return
	end
	if run.stage == "Start" then
		if busy then
			return
		end
		if step.kind == "Look" then
			startHold(ctx, run, step)
		else
			run.stage = "Travel"
			mover:GoTo(step.position, { arrive = SPOT_ARRIVE })
		end
		return
	end
	if run.stage == "Travel" then
		if busy or status == "Moving" then
			return
		end
		if status == "Failed" or status == "Stuck" then
			nextStep(ctx, run)
			return
		end
		startHold(ctx, run, step)
		return
	end
	if Sniff.waiting(ctx, run.inspection) or busy then
		return
	end
	nextStep(ctx, run)
end

function InvestigateNoise.exit(ctx: Context, _to: Enums.MonsterState)
	local run = runOf(ctx)
	run.inspection = nil
	ctx.body:SetPose("Biped")
	ctx.body:Face(nil)
	ctx.investigation = nil
end

return table.freeze(InvestigateNoise)
