--!strict
-- AquaticStalk: the pool level (Level 4). Someone is swimming, so the Creature slips under the murky surface (a
-- kinematic glide, PoseMode Swim, SwimDepth down) and stalks the noise: toward the swimmer while it can see them
-- (underwater players are only seen by a swimming Creature), else toward the latest splash it heard, else to where it
-- last sensed them.
--
-- The grab itself belongs to the pool system (P7) through the PoolGrabber hook. Once a swimmer's splashing has crossed
-- the grab threshold (NoiseAndDirectorService.SplashThresholdCrossed, remembered for a while), the Creature closes in
-- fast (AquaticLunge speed) from below and, within GrabReach, calls the hook; a grab that starts holds it there
-- (GrabbedUserId) until the pool system lets go. Without a hook registered it circles under them and never grabs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CreatureConfig = require(ReplicatedStorage.Shared.Config.CreatureConfig)
local DifficultyConfig = require(ReplicatedStorage.Shared.Config.DifficultyConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)

local Brain = require(script.Parent.Parent.Brain)
local Locomotion = require(script.Parent.Parent.Locomotion)

type Context = Brain.Context

type Run = { holding: boolean, circle: number }

local NAME: Enums.MonsterState = "AquaticStalk"
local LUNGE_RANGE = 12
local GRAB_REACH = 4.5
local LUNGE_DEPTH = 1.2 -- the lunge comes up close under the surface
local UNDER = 2 -- studs below the swimmer it aims for
local CIRCLE_RADIUS = 6
local CIRCLE_SPEED = 0.6 -- radians per second around a swimmer it may not grab

local AquaticStalk = {}

AquaticStalk.Name = NAME
AquaticStalk.LungeRange = LUNGE_RANGE
AquaticStalk.GrabReach = GRAB_REACH

local runs: { [Context]: Run } = setmetatable({}, { __mode = "k" }) :: any

local function runOf(ctx: Context): Run
	local run = runs[ctx]
	if not run then
		run = { holding = false, circle = 0 }
		runs[ctx] = run
	end
	return run
end

-- Whether the Creature lunges at a swimmer `distance` away (only once their splashing armed a grab, and only when
-- someone can actually grab).
function AquaticStalk.shouldLunge(distance: number, armed: boolean, grabber: boolean): boolean
	return armed and grabber and distance <= LUNGE_RANGE
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
	local lunging = target ~= nil
		and swimmerRoot ~= nil
		and AquaticStalk.shouldLunge((swimmerRoot - here).Magnitude, ctx.grabArmed(target), grabber ~= nil)
	if lunging and target and swimmerRoot and grabber then
		if (swimmerRoot - here).Magnitude <= GRAB_REACH and mover:Medium() == "Water" then
			local ok, started = pcall(grabber, target)
			if ok and started then
				run.holding = true
				mover:Stop()
				ctx.setGrabbed(target)
				return
			end
		end
		mover:SetSpeed(speedFor(ctx, true))
		mover:GoTo(swimmerRoot - Vector3.new(0, UNDER, 0), { arrive = 1, depth = LUNGE_DEPTH })
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
	if run.holding then
		run.holding = false
		ctx.setGrabbed(nil)
	end
end

-- The pool system let go (MonsterAIService clears GrabbedUserId): the Creature may move again.
function AquaticStalk.released(ctx: Context)
	runOf(ctx).holding = false
end

return table.freeze(AquaticStalk)
