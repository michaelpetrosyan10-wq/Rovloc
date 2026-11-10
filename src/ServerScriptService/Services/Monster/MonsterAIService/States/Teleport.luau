--!strict
-- Teleport (docs/MONSTER.md 6.8 and 7.2, THRESHOLD's jumpscare engine). Every minute or two, when nobody has been seen
-- for UnseenSeconds and it is only stalking, the Creature relocates next to a player:
--
--   * the service picks the target (weighted: isolated from the squad, loud lately, not targeted last time) and the
--     spot (12..24 studs of walking from them, behind them in the tunnel they came through 60 % of the time, else round
--     the next corner ahead; out of every player's view, never within 12 studs of anyone, never in a crawlway or in the
--     keep-room they stand in), then runs the warp: FadeOut where it is, hidden, placed, the WarningSeconds warning (the
--     lights near the spot stutter, the target's torch stutters, a static hiss rises), the spot checked again (in view
--     now: another spot, another warning), FadeIn, and the Stare: StareSeconds standing still, staring. A target who
--     turns and looks at it then gets the reveal scare (no damage).
--   * Then it stalks the target at the Teleport pace for StalkSeconds; meanwhile sight alone does not start a chase,
--     only a held stare or the target coming within StalkNear (the service's summary). Then it patrols.
-- Never during a chase, a search, a hiding response or a scripted beat; never within AfterCatch of a catch or of someone
-- going down; never while the game blocks it (an objective's survive countdown, the roof's finale); the first on a floor
-- no sooner than its grace + FirstAfterGrace.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)

local Brain = require(script.Parent.Parent.Brain)

type Context = Brain.Context

export type Side = "Behind" | "Ahead" | "Side"

export type Weighing = { isolated: boolean, loud: boolean, lastTarget: boolean }

type Run = { plan: Brain.TeleportPlan?, phase: "Warp" | "Stalk", stalkUntil: number, nextGoalAt: number }

local NAME: Enums.MonsterState = "Teleport"
local T = CreatureConfig.Teleport
local REGOAL_SECONDS = 1
local ISOLATED_WEIGHT = 2
local LOUD_WEIGHT = 1.6
local FRESH_WEIGHT = 1.5
local BEHIND_TRAIL = 6
local AHEAD_DOT = 0.25

local Teleport = {}

Teleport.Name = NAME
Teleport.IsolatedWeight = ISOLATED_WEIGHT
Teleport.LoudWeight = LOUD_WEIGHT
Teleport.FreshWeight = FRESH_WEIGHT

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

-- A target's weight: isolated from teammates, loud lately, and not the last one picked all weigh more.
function Teleport.targetWeight(w: Weighing): number
	return (if w.isolated then ISOLATED_WEIGHT else 1)
		* (if w.loud then LOUD_WEIGHT else 1)
		* (if w.lastTarget then 1 else FRESH_WEIGHT)
end

-- The item a roll in [0, 1) lands on, by weight (nil for an empty list).
function Teleport.pickWeighted<T>(items: { T }, weights: { number }, roll: number): T?
	local total = 0
	for _, w in weights do
		total += math.max(0, w)
	end
	if not (total > 0) then
		return items[1]
	end
	local at = roll * total
	for i, item in items do
		at -= math.max(0, weights[i])
		if at < 0 then
			return item
		end
	end
	return items[#items]
end

-- Where a candidate floor point lies for a target at root `target`: "Behind" (on the way they came: near their trail of
-- the last seconds, not in front of their look), "Ahead" (in front of their travel, else their look) or "Side".
function Teleport.classify(point: Vector3, target: Vector3, trail: { Vector3 }, look: Vector3, travel: Vector3?): Side
	local dx, dz = point.X - target.X, point.Z - target.Z
	local len = math.sqrt(dx * dx + dz * dz)
	if len == 0 then
		len = 1
	end
	local lookLen = math.sqrt(look.X * look.X + look.Z * look.Z)
	if lookLen == 0 then
		lookLen = 1
	end
	local lookDot = (look.X * dx + look.Z * dz) / (len * lookLen)
	local nearTrail = false
	for _, p in trail do
		if math.sqrt((p.X - point.X) ^ 2 + (p.Z - point.Z) ^ 2) <= BEHIND_TRAIL then
			nearTrail = true
			break
		end
	end
	if nearTrail and lookDot < AHEAD_DOT then
		return "Behind"
	end
	local ahead = if travel then (travel.X * dx + travel.Z * dz) / len else lookDot
	if ahead > AHEAD_DOT then
		return "Ahead"
	end
	return if lookDot < -AHEAD_DOT then "Behind" else "Side"
end

local function runOf(ctx: Context): Run
	local run = runs[ctx]
	if not run then
		run = { plan = nil, phase = "Warp", stalkUntil = 0, nextGoalAt = 0 }
		runs[ctx] = run
	end
	return run
end

-- Whether the stalk after the stare runs (the summary's sight rule).
function Teleport.stalking(ctx: Context): boolean
	local run = runs[ctx]
	return run ~= nil and run.plan ~= nil
end

function Teleport.enter(ctx: Context, _from: Enums.MonsterState)
	local run = runOf(ctx)
	local plan = ctx.teleportPlan
	run.plan = plan
	run.phase = "Warp"
	run.nextGoalAt = 0
	if not plan or not ctx.startTeleport(plan) then
		run.plan = nil
		ctx.stateDone = true
	end
end

function Teleport.update(ctx: Context, _dt: number)
	local run = runOf(ctx)
	local plan = run.plan
	if not plan then
		ctx.stateDone = true
		return
	end
	if ctx.warping() then
		return
	end
	local now = ctx.now()
	if run.phase == "Warp" then
		run.phase = "Stalk"
		run.stalkUntil = now + T.StalkSeconds
		local speed = ctx.speedOf(NAME)
		ctx.mover:SetSpeed(speed)
		ctx.body:SetWalkSpeed(speed)
		ctx.mover:SetRepathInterval(CreatureConfig.Repath.PatrolInterval / 2)
		ctx.setTarget(plan.target)
	end
	local target = plan.target
	if now > run.stalkUntil or not ctx.playing(target) or ctx.isHiding(target) or ctx.inVent(target) then
		ctx.stateDone = true
		return
	end
	if now < run.nextGoalAt or ctx.mover:Busy() then
		return
	end
	run.nextGoalAt = now + REGOAL_SECONDS
	local root = ctx.rootOf(target)
	if root then
		ctx.mover:GoTo(ctx.floorPointNear(root), { arrive = 2 })
	end
end

function Teleport.exit(ctx: Context, _to: Enums.MonsterState)
	local run = runOf(ctx)
	run.plan = nil
	ctx.teleportPlan = nil
	ctx.body:Face(nil)
end

return table.freeze(Teleport)
