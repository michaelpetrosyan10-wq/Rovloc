--!strict
-- HidingResponse (docs/MONSTER.md 6.7: THRESHOLD's barrel rule with a fair outplay). The Creature saw someone climb into
-- a hiding spot (a locker, a barrel, a cabinet): it comes and stands facing the spot, StandOff studs out from its front.
--
--   * Every LookAwayMin..LookAwayMax seconds it does a LookAway: a low grunt GruntLead seconds before (the tell), then
--     for LookAwaySeconds its head turns down the tunnel (the open side) and it neither sees toward the spot nor feels
--     anything close (the service's perception uses the look-away facing, no peripheral sense). Slipping out then and
--     breaking the line of sight escapes. A LookAway that would still run within ReachInLead of the reach is skipped.
--   * ReachInSeconds (Nightmare: less) after they got in it reaches in: the ReachIn action, then a Locker catch.
--   * Stepping out while it is not looking away, within CatchRange (and 5 vertical) with a clear chest line, is a catch
--     (Hallway).
--   * A teammate pulling them out (HideSpotService, THRESHOLD's throw) is no catch: the pull startles it for a moment
--     (the service) and the brain moves on (WallChase on whoever it sees, else Search).
--   * Done when the hider is out (or taken, or gone); the brain decides what follows.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local Brain = require(script.Parent.Parent.Brain)

type Context = Brain.Context

type Run = {
	watch: Brain.HideWatch?,
	phase: "Approach" | "Watch",
	stand: Vector3,
	nextLookAt: number,
	lookAwayUntil: number?,
	gruntAt: number,
	grunted: boolean,
	reachAt: number,
	reached: boolean,
}

local NAME: Enums.MonsterState = "HidingResponse"
local H = CreatureConfig.Hiding
local ARRIVE = 1

local HidingResponse = {}

HidingResponse.Name = NAME

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

local function runOf(ctx: Context): Run
	local run = runs[ctx]
	if not run then
		run = {
			watch = nil,
			phase = "Approach",
			stand = Vector3.zero,
			nextLookAt = math.huge,
			lookAwayUntil = nil,
			gruntAt = math.huge,
			grunted = false,
			reachAt = math.huge,
			reached = false,
		}
		runs[ctx] = run
	end
	return run
end

-- Where it stands: StandOff out from the spot's front (its exit anchor, facing out of the spot).
function HidingResponse.standPoint(front: CFrame): Vector3
	local look = front.LookVector
	local out = Vector3.new(look.X, 0, look.Z)
	out = if out.Magnitude < 1e-6 then Vector3.new(0, 0, -1) else out.Unit
	return front.Position + out * (H.StandOff - 1)
end

-- Whether it is looking away right now.
function HidingResponse.lookingAway(ctx: Context): boolean
	local run = runs[ctx]
	return run ~= nil and run.lookAwayUntil ~= nil
end

local function scheduleLook(ctx: Context, run: Run, now: number)
	run.nextLookAt = now + ctx.random:NextNumber(H.LookAwayMin, H.LookAwayMax)
	run.gruntAt = run.nextLookAt - H.GruntLead
	run.grunted = false
end

local function faceSpot(ctx: Context, watch: Brain.HideWatch)
	ctx.mover:Face(-watch.front.LookVector)
end

function HidingResponse.enter(ctx: Context, _from: Enums.MonsterState)
	local run = runOf(ctx)
	local watch = ctx.hiding
	run.watch = watch
	run.phase = "Approach"
	run.lookAwayUntil = nil
	run.nextLookAt = math.huge
	run.gruntAt = math.huge
	run.reached = false
	ctx.setLookAway(nil)
	if not watch then
		ctx.stateDone = true
		return
	end
	run.reachAt = watch.since + Brain.difficultySpec(ctx.difficulty).reachInSeconds
	run.stand = HidingResponse.standPoint(watch.front)
	local speed = math.min(ctx.speedOf("WallChase"), CreatureConfig.Speeds.InvestigateNoise)
	ctx.mover:SetSpeed(speed)
	ctx.body:SetWalkSpeed(speed)
	ctx.mover:SetRepathInterval(CreatureConfig.Repath.ChaseInterval)
	if ctx.mover:Medium() == "Floor" then
		ctx.body:SetPose("Biped")
	end
	ctx.body:Face(nil)
	ctx.mover:GoTo(run.stand, { arrive = ARRIVE })
end

function HidingResponse.update(ctx: Context, _dt: number)
	local run = runOf(ctx)
	local watch = run.watch
	if not watch then
		ctx.stateDone = true
		return
	end
	local hider = watch.player
	local now = ctx.now()
	if not ctx.playing(hider) then
		ctx.stateDone = true
		return
	end
	if not ctx.isHiding(hider) then
		-- out of the spot: slipped out while it looked away (it notices nothing until the LookAway is over: whoever has
		-- broken the line by then is gone), pulled by a teammate (no catch), or stepped out under its nose (a catch)
		local lookingUntil = run.lookAwayUntil
		if lookingUntil ~= nil and now < lookingUntil then
			return
		end
		if not ctx.pulledOut(hider) and run.lookAwayUntil == nil then
			local root = ctx.rootOf(hider)
			local here = ctx.body:GetPosition()
			if
				root
				and MathUtil.horizontalDistance(root, here) <= H.CatchRange
				and math.abs(root.Y - here.Y) <= CreatureConfig.Senses.CatchVertical
				and ctx.bodyClear(hider)
			then
				ctx.tryCatch(hider, "Hallway")
			end
		end
		ctx.setLookAway(nil)
		ctx.stateDone = true
		return
	end
	if ctx.hideSpotOf(hider) ~= watch.spot then
		ctx.stateDone = true
		return
	end
	local mover = ctx.mover
	if run.phase == "Approach" then
		local status = mover:Status()
		if status == "Failed" or status == "Stuck" then
			ctx.stateDone = true
			return
		end
		if mover:Busy() or status == "Moving" then
			return
		end
		run.phase = "Watch"
		mover:Stop()
		faceSpot(ctx, watch)
		scheduleLook(ctx, run, now)
		return
	end
	-- the reach: ReachInSeconds after they got in
	if now >= run.reachAt then
		if not run.reached then
			run.reached = true
			run.lookAwayUntil = nil
			ctx.setLookAway(nil)
			faceSpot(ctx, watch)
			ctx.reachIn(hider, watch.spot)
		end
		return
	end
	local lookingUntil = run.lookAwayUntil
	if lookingUntil ~= nil then
		if now < lookingUntil then
			return
		end
		run.lookAwayUntil = nil
		ctx.setLookAway(nil)
		faceSpot(ctx, watch)
		scheduleLook(ctx, run, now)
		return
	end
	-- a LookAway that would still run when it reaches in is skipped
	if run.nextLookAt + H.LookAwaySeconds > run.reachAt - H.ReachInLead then
		run.nextLookAt = math.huge
		run.gruntAt = math.huge
	end
	if not run.grunted and now >= run.gruntAt then
		run.grunted = true
		ctx.grunt()
	end
	if now >= run.nextLookAt then
		run.lookAwayUntil = now + H.LookAwaySeconds
		ctx.setLookAway(ctx.lookAwayDirection(watch.front))
	end
end

function HidingResponse.exit(ctx: Context, _to: Enums.MonsterState)
	local run = runOf(ctx)
	run.watch = nil
	run.lookAwayUntil = nil
	ctx.setLookAway(nil)
	ctx.body:Face(nil)
	ctx.hiding = nil
end

return table.freeze(HidingResponse)
