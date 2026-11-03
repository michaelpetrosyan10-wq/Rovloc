--!strict
-- WallChase: the Creature has seen someone and runs them down on two legs, at WallChase speed x the difficulty's
-- multiplier, re-routing every Repath.ChaseInterval (and walking straight at them when the way is clear and close).
--
--   * Goal: the target while they are in sight; once they are not, the last place it saw or heard them (the brain's
--     memory, MemorySeconds long). Reaching that spot with nobody in sight ends the chase: the brain searches the
--     area (InvestigateNoise).
--   * Catches: anyone in sight within CatchDistance (same floor, clear line, the brain's catch rules) is caught as a
--     "Hallway" jumpscare; the target first.
--   * An unreachable target (no route) is retried a moment later while still in sight; an unreachable memory ends
--     the chase.
-- The brain breaks the chase off when it has run too long or the pacing calls a breather, and switches to VentChase
-- when the target is seen crawling into a duct.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)

local Brain = require(script.Parent.Parent.Brain)

type Context = Brain.Context

type Run = { retryAt: number }

local NAME: Enums.MonsterState = "WallChase"
local RETRY_SECONDS = 1
local MEMORY_REACHED = 4 -- studs from the remembered spot that count as there

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
	local run = runOf(ctx)
	run.retryAt = 0
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
