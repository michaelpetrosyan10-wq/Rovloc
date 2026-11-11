--!strict
-- WallChase (the Chase, docs/MONSTER.md 6.5): the Creature saw someone (or was stared at) and runs them down at 16.5
-- studs/s (x the difficulty, never past SpeedCap: a sprinting player, 19, gains on it; a walking one loses ground),
-- re-routing every Repath.ChaseInterval (and walking straight at them when the way is clear and close).
--
--   * Goal: the target while in sight (arrive 1); once not, the last place it saw or heard them (arrive 2).
--   * Catches: anyone in sight within the catch reach (4 studs, the same floor, a clear line eye to eye and chest to
--     chest: never through a wall; Brain.catchKind) is caught as a Hallway jumpscare; the target first.
--   * Ends (the brain): after ChaseLost seconds without a sight of its quarry, or on reaching the last seen point with
--     nobody in sight, it searches there (Search); MaxChase seconds in, it gives up and fades out (Patrol).
--   * An unreachable target (no route) is retried a moment later while still in sight; an unreachable memory ends it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local Brain = require(script.Parent.Parent.Brain)

type Context = Brain.Context

type Run = { retryAt: number }

local NAME: Enums.MonsterState = "WallChase"
local RETRY_SECONDS = 1
local MEMORY_REACHED = 4

local WallChase = {}

WallChase.Name = NAME

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

local function runOf(ctx: Context): Run
	local run = runs[ctx]
	if not run then
		run = { retryAt = 0 }
		runs[ctx] = run
	end
	return run
end

-- The players in sight, the target first (the order catches are tried in).
function WallChase.catchOrder(sightings: { Player }, target: Player?): { Player }
	local order: { Player } = {}
	if target and table.find(sightings, target) then
		table.insert(order, target)
	end
	for _, player in sightings do
		if player ~= target then
			table.insert(order, player)
		end
	end
	return order
end

local function inSight(ctx: Context, player: Player): boolean
	for _, sighting in ctx.sightings do
		if sighting.player == player then
			return true
		end
	end
	return false
end

function WallChase.enter(ctx: Context, _from: Enums.MonsterState)
	runOf(ctx).retryAt = 0
	local speed = ctx.speedOf(NAME)
	ctx.mover:SetSpeed(speed)
	ctx.body:SetWalkSpeed(speed)
	ctx.mover:SetRepathInterval(CreatureConfig.Repath.ChaseInterval)
	ctx.body:SetPose("Biped")
	ctx.body:Face(nil)
end

function WallChase.update(ctx: Context, _dt: number)
	local run = runOf(ctx)
	local seen: { Player } = {}
	for _, sighting in ctx.sightings do
		table.insert(seen, sighting.player)
	end
	for _, player in WallChase.catchOrder(seen, ctx.target) do
		local kind = ctx.catchKind(player)
		if kind and ctx.tryCatch(player, kind :: Enums.JumpscareKind) then
			return
		end
	end
	local target = ctx.target
	local memory = ctx.memory
	local visible = target ~= nil and inSight(ctx, target)
	local goal: Vector3? = nil
	if visible and target then
		goal = ctx.rootOf(target)
	elseif memory then
		goal = memory.position
	end
	if not goal then
		ctx.stateDone = true
		return
	end
	local mover = ctx.mover
	local status = mover:Status()
	local now = ctx.now()
	if status == "Failed" or status == "Stuck" then
		if not visible then
			ctx.stateDone = true
			return
		end
		if now < run.retryAt then
			return
		end
	end
	if
		not visible
		and status ~= "Moving"
		and MathUtil.horizontalDistance(ctx.body:GetPosition(), goal) <= MEMORY_REACHED
	then
		ctx.stateDone = true
		return
	end
	if mover:Busy() then
		return
	end
	run.retryAt = now + RETRY_SECONDS
	mover:GoTo(goal, { arrive = if visible then 1 else 2 })
end

function WallChase.exit(_ctx: Context, _to: Enums.MonsterState) end

return table.freeze(WallChase)
