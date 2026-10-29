--!strict
-- AquaticStalk: the pool level (Level 4). Someone is swimming, so the Creature slips under the murky surface (a
-- kinematic glide, PoseMode Swim, SwimDepth down) and stalks the noise: toward the swimmer while it can see them
-- (underwater players are only seen by a swimming Creature), else toward the latest splash it heard, else to where it
-- last sensed them. It stalks at the AquaticStalk pace (6.5, Floor 4 fairness): a freestyle swimmer (9) outswims it, one
-- treading water (4) does not.
--
-- The grab itself belongs to the pool system (P7) through the PoolGrabber hook. Once a swimmer's splashing has crossed
-- the grab threshold (NoiseAndDirectorService.SplashThresholdCrossed, remembered for a while) and they are within
-- LungeRange, the Creature TELEGRAPHS: it holds still for CreatureConfig.Water.TelegraphSeconds while its lunge origin
-- gives it away (ctx.telegraph: a low growl there, and the clients' rising bubbles and ripple ring), so the swimmer can
-- climb out or swim off. Only then does it close in fast (AquaticLunge) from below, for at most LungeWindow, and within
-- GrabReach call the hook; a grab that starts holds it there (GrabbedUserId) until the pool system lets go. A lunge
-- that misses (the swimmer out of reach or out of the water) waits LungeCooldown before the next telegraph. Without a
-- hook registered it circles under them and never grabs. While the brain has it retreating after a grab
-- (ctx.poolRetreat), it swims to the far end of the water and never lunges.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)

local Brain = require(script.Parent.Parent.Brain)
local Locomotion = require(script.Parent.Parent.Locomotion)

type Context = Brain.Context

type Run = {
	holding: boolean,
	circle: number,
	telegraphUntil: number?, -- held still, the lunge being telegraphed until then
	lungeUntil: number?, -- the lunge may run until then
	nextTelegraphAt: number,
}

local WATER = CreatureConfig.Water
local NAME: Enums.MonsterState = "AquaticStalk"
local LUNGE_RANGE = WATER.LungeRange
local GRAB_REACH = 4.5
local LUNGE_DEPTH = 1.2 -- the lunge comes up close under the surface
local UNDER = 2 -- studs below the swimmer it aims for
local CIRCLE_RADIUS = 6
local CIRCLE_SPEED = 0.6 -- radians per second around a swimmer it may not grab
local TELEGRAPH_BREAK = 1.5 -- a telegraph is called off when the swimmer gets this many lunge ranges away

local AquaticStalk = {}

AquaticStalk.Name = NAME
AquaticStalk.LungeRange = LUNGE_RANGE
AquaticStalk.GrabReach = GRAB_REACH
AquaticStalk.TelegraphSeconds = WATER.TelegraphSeconds
AquaticStalk.LungeWindow = WATER.LungeWindow
AquaticStalk.LungeCooldown = WATER.LungeCooldown

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

local function runOf(ctx: Context): Run
	local run = runs[ctx]
	if not run then
		run = { holding = false, circle = 0, telegraphUntil = nil, lungeUntil = nil, nextTelegraphAt = 0 }
		runs[ctx] = run
	end
	return run
end

-- Whether the Creature wants to lunge at a swimmer `distance` away (only once their splashing armed a grab, and only
-- when someone can actually grab). Every lunge is telegraphed first.
function AquaticStalk.shouldLunge(distance: number, armed: boolean, grabber: boolean): boolean
	return armed and grabber and distance <= LUNGE_RANGE
end

-- Whether a lunge is being telegraphed now (dev reads and specs).
function AquaticStalk.telegraphing(ctx: Context): boolean
	local run = runs[ctx]
	return run ~= nil and run.telegraphUntil ~= nil
end

local function inSight(ctx: Context, player: Player): boolean
	for _, sighting in ctx.sightings do
		if sighting.player == player then
			return true
		end
	end
	return false
end

local function speedFor(ctx: Context, lunging: boolean): number
	if not lunging then
		return ctx.speedOf(NAME)
	end
	local spec = DifficultyConfig[ctx.difficulty] or DifficultyConfig.Standard
	return CreatureConfig.Speeds.AquaticLunge * spec.creatureSpeedMultiplier
end

function AquaticStalk.enter(ctx: Context, _from: Enums.MonsterState)
	local run = runOf(ctx)
	run.holding = false
	run.telegraphUntil = nil
	run.lungeUntil = nil
	run.circle = ctx.random:NextNumber(0, math.pi * 2)
	ctx.mover:SetSpeed(ctx.speedOf(NAME))
	ctx.body:SetWalkSpeed(ctx.speedOf(NAME))
	ctx.mover:SetRepathInterval(CreatureConfig.Repath.ChaseInterval)
	ctx.body:Face(nil)
end

function AquaticStalk.update(ctx: Context, dt: number)
	local run = runOf(ctx)
	if run.holding then
		return
	end
	local mover = ctx.mover
	if mover:Busy() then
		return
	end
	local now = ctx.now()
	-- after a grab: off to the far end of the water, no lunges
	local retreat = if ctx.poolRetreat then ctx.poolRetreat() else nil
	if retreat then
		run.telegraphUntil = nil
		run.lungeUntil = nil
		mover:SetSpeed(speedFor(ctx, false))
		mover:GoTo(retreat, { arrive = 2, depth = Locomotion.SwimDepth })
		return
	end
	local target = ctx.target
	local heard = ctx.heard
	local goal: Vector3? = nil
	local swimmerRoot = if target then ctx.rootOf(target) else nil
	if target and swimmerRoot and inSight(ctx, target) then
		goal = swimmerRoot
	elseif heard and heard.medium == "Water" then
		goal = heard.position
	else
		local memory = ctx.memory
		goal = if memory then memory.position else swimmerRoot
	end
	if not goal then
		return
	end
	local here = ctx.body:GetPosition()
	local grabber = ctx.poolGrabber()
	local swimming = target ~= nil and swimmerRoot ~= nil and ctx.swimming(target)
	local distance = if swimmerRoot then (swimmerRoot - here).Magnitude else math.huge
	local inWater = mover:Medium() == "Water"
	local wants = swimming
		and target ~= nil
		and AquaticStalk.shouldLunge(distance, ctx.grabArmed(target), grabber ~= nil)
	-- the telegraph: held still at the lunge origin while the cues play there
	local telegraphUntil = run.telegraphUntil
	if telegraphUntil then
		if not swimming or distance > LUNGE_RANGE * TELEGRAPH_BREAK or not inWater then
			run.telegraphUntil = nil
			run.nextTelegraphAt = now + WATER.LungeCooldown
		elseif now < telegraphUntil then
			mover:Stop()
			return
		else
			run.telegraphUntil = nil
			run.lungeUntil = now + WATER.LungeWindow
		end
	end
	local lungeUntil = run.lungeUntil
	if lungeUntil and (now > lungeUntil or not swimming or not inWater) then
		run.lungeUntil = nil
		run.nextTelegraphAt = now + WATER.LungeCooldown
	end
	if run.lungeUntil == nil and wants and now >= run.nextTelegraphAt and inWater then
		run.telegraphUntil = now + WATER.TelegraphSeconds
		mover:Stop()
		local telegraph = ctx.telegraph
		if telegraph then
			telegraph(here, WATER.TelegraphSeconds)
		end
		return
	end
	if run.lungeUntil ~= nil and target and swimmerRoot and grabber then
		if distance <= GRAB_REACH and inWater then
			local ok, started = pcall(grabber, target)
			if ok and started then
				run.holding = true
				run.lungeUntil = nil
				mover:Stop()
				ctx.setGrabbed(target)
				return
			end
		end
		mover:SetSpeed(speedFor(ctx, true))
		mover:GoTo(swimmerRoot - Vector3.new(0, UNDER, 0), { arrive = 1, depth = LUNGE_DEPTH, lunge = true })
		return
	end
	mover:SetSpeed(speedFor(ctx, false))
	local aim = goal - Vector3.new(0, UNDER, 0)
	local basin = mover:BasinAt(aim) or mover:BasinAt(goal)
	if basin and (aim - here).Magnitude <= CIRCLE_RADIUS * 1.5 then
		-- close under a swimmer it may not take: circle beneath them
		run.circle += CIRCLE_SPEED * dt
		aim = goal + Vector3.new(math.cos(run.circle) * CIRCLE_RADIUS, -UNDER, math.sin(run.circle) * CIRCLE_RADIUS)
	end
	mover:GoTo(aim, { arrive = 1.5, depth = Locomotion.SwimDepth })
end

function AquaticStalk.exit(ctx: Context, _to: Enums.MonsterState)
	local run = runOf(ctx)
	run.telegraphUntil = nil
	run.lungeUntil = nil
	if run.holding then
		run.holding = false
		ctx.setGrabbed(nil)
	end
end

-- The pool system let go (MonsterAIService clears GrabbedUserId): the Creature may move again, after a cooldown.
function AquaticStalk.released(ctx: Context)
	local run = runOf(ctx)
	run.holding = false
	run.telegraphUntil = nil
	run.lungeUntil = nil
	run.nextTelegraphAt = ctx.now() + WATER.LungeCooldown
end

return table.freeze(AquaticStalk)
